package com.nicksullivan.epaper_nfc

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.tech.NfcA
import android.nfc.tech.TagTechnology
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.lifecycle.FlutterLifecycleAdapter
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Owns the NFC radio, and nothing else.
 *
 * The panel's protocol and pixel packing live in Dart. This class exists only because the two
 * things Dart cannot do are the two things this hardware needs: reader mode with a stretched
 * presence check, and a raw ISO-DEP channel. It hands bytes back and forth and takes no view on
 * what they mean.
 *
 * Reader mode, never foreground dispatch: only reader mode lets us stretch the presence check,
 * skip the NDEF read at connect, and keep the platform's own tag handling out of the session.
 *
 * Reader mode belongs to an activity, so this follows the host activity's lifecycle: on when it
 * resumes, off when it pauses, and nowhere else.
 */
class EpaperNfcPlugin : FlutterPlugin, ActivityAware, NfcAdapter.ReaderCallback {

    private companion object {
        const val EVENT_CHANNEL = "epaper_nfc/tag_events"
        const val METHOD_CHANNEL = "epaper_nfc/session"

        /** `adb logcat -s epapernfc` gives a full APDU trace. */
        const val LOG_TAG = "epapernfc"

        /**
         * The single biggest reliability lever. The platform default (~125ms) shreds a long write.
         *
         * Measured on a Pixel 10a, 2026-09-25: at 5000 the hold died at *exactly* 5 s, every time —
         * this is not a timeout to survive, it is the platform reaching in and invalidating the tag
         * handle on a cadence we choose. So it is set well beyond any plausible write duration.
         * A full four-colour refresh takes ~16 s by Waveshare's own documentation.
         *
         * Cost of a large value: if the panel is physically removed, the platform won't notice for
         * this long. That is fine here — [holdAndMeasure] detects loss from the connection itself.
         */
        const val PRESENCE_CHECK_DELAY_MS = 60_000

        /** What the vendor app uses for ISO-DEP. A refresh poll can legitimately block for ages. */
        const val ISO_DEP_TIMEOUT_MS = 50_000

        /** For a raw NfcA session from the diagnostics console. */
        const val NFCA_TIMEOUT_MS = 1200

        const val POLL_INTERVAL_MS = 250L

        /** How often the idle monitor actually proves the panel is still there. See [probe]. */
        const val PROBE_INTERVAL_MS = 1000L

        /**
         * CLA 00, INS 00: an instruction ISO 7816-4 leaves undefined, so every panel refuses it —
         * the 4.2" bridge and the (G) both answer unknown commands with an error status, which is
         * all [probe] needs. It changes nothing on the panel.
         */
        val PRESENCE_PING = byteArrayOf(0x00, 0x00, 0x00, 0x00)

        /** A present panel answers in milliseconds. */
        const val PING_TIMEOUT_MS = 1000
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    private var activity: Activity? = null
    private var lifecycle: Lifecycle? = null
    private var nfcAdapter: NfcAdapter? = null
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    /** All tag I/O is serialised here. `transceive` blocks and must never touch the main thread. */
    private val nfcExecutor = Executors.newSingleThreadExecutor()

    /** Bumped on every discovery; a rising count during one hold means the session keeps dropping. */
    private var discoveryCount = 0

    /**
     * Identifies the current discovery. A re-discovery invalidates the previous [Tag] handle, so the
     * thread watching it must stand down rather than keep polling a dead object.
     */
    private val sessionId = AtomicInteger(0)

    @Volatile
    private var monitoring = false

    /**
     * The idle monitor's connection to the current tag: [IsoDep] whenever the tag has it, which both
     * panels do, and [NfcA] only for a tag that doesn't.
     *
     * **Stay on the interface the tag arrives on.** The panels are dual-interface (the 4.2" reports
     * IsoDep, NfcA and MifareClassic, SAK 28). Connecting as NfcA makes the controller switch the
     * tag's RF interface from ISO-DEP to frame — deactivate it and re-select it — and switching back
     * for a write does it again. The monitor used to hold NfcA and reconnect it every second, so a
     * panel resting on the phone was re-selected across interfaces once a second, and ~40% of those
     * re-selects failed (`NFA_SELECT_RESULT_EVT error`, `reSelect: timeout` in logcat). That churn is
     * the prime suspect for the phone's NFC getting steadily worse until NFC was toggled
     * (2026-10-10). A write now reuses this very connection, so a normal write switches nothing.
     */
    @Volatile
    private var monitor: TagTechnology? = null

    @Volatile
    private var currentTag: Tag? = null

    /** The open ISO-DEP channel while Dart has a session running — the monitor's, borrowed. */
    @Volatile
    private var isoDep: IsoDep? = null

    /** The NfcA connection, when Dart opened a raw session instead. See [openSession]. */
    @Volatile
    private var rawNfcA: NfcA? = null

    /**
     * Set while Dart owns the tag. The idle monitor's [probe] tears the connection down and rebuilds
     * it, which mid-transfer is exactly the interruption this project exists to avoid.
     */
    @Volatile
    private var busy = false

    /**
     * Held by [probe] and by opening and closing a session. A session borrows the monitor's own
     * connection, so a probe caught halfway through its close-and-reconnect would otherwise pull it
     * out from under the write.
     */
    private val tagLock = Any()

    // ------------------------------------------------------------------------------------ engine

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // From the application context, not the activity: Dart may subscribe to tag events before
        // an activity attaches, and the adapter state it gets then has to be the real one.
        nfcAdapter = NfcAdapter.getDefaultAdapter(binding.applicationContext)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).apply {
            setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                        events = sink
                        emitAdapterState()
                    }

                    override fun onCancel(arguments: Any?) {
                        events = null
                    }
                }
            )
        }

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSession" -> {
                        val tech = call.arguments as? String ?: "isoDep"
                        onNfcThread(result) { openSession(tech) }
                    }
                    "transceive" -> {
                        val data = call.arguments as? ByteArray
                        if (data == null) {
                            result.error("bad_args", "Expected a byte array.", null)
                        } else {
                            onNfcThread(result) { transceive(data) }
                        }
                    }
                    "closeSession" -> onNfcThread(result) { closeSession() }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        events = null
    }

    // ---------------------------------------------------------------------------------- activity

    /**
     * Reader mode on when the activity resumes, off when it pauses — the same two places the app's
     * own activity used to do it, and the only two.
     *
     * No field resets. A version of this app turned the field off and on (reader mode off,
     * setDiscoveryTechnology(READER_DISABLE), back on) whenever the panel was lost — to un-stick a
     * panel that went deaf after a dropped link. It left the phone's NFC unable to power the 4.2"'s
     * refresh, anywhere, until NFC was switched off and on in settings: with it, a refresh after a
     * failure ran 8% of the time; without it, 16 of 16 ran, in spots that had been failing all
     * morning (2026-10-10). A deaf panel is cured by lifting it away instead.
     */
    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) {
            enableReader()
            emitAdapterState()
        }

        override fun onPause(owner: LifecycleOwner) {
            monitoring = false
            runCatching { isoDep?.close() }
            isoDep = null
            val activity = activity ?: return
            nfcAdapter?.disableReaderMode(activity)
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        // Added before the activity resumes, so the first ON_RESUME is the one that enables reader
        // mode. Were it added later, the lifecycle would replay ON_RESUME to it straight away.
        lifecycle = FlutterLifecycleAdapter.getActivityLifecycle(binding).also {
            it.addObserver(lifecycleObserver)
        }
    }

    override fun onDetachedFromActivity() {
        // The activity has already paused, which turned reader mode off. Turning it off again here
        // would be exactly the kind of extra toggling that degraded the phone's NFC.
        lifecycle?.removeObserver(lifecycleObserver)
        lifecycle = null
        activity = null
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    // ------------------------------------------------------------------------------------ session

    /**
     * Runs [work] on the NFC thread and answers [result] exactly once, on the main thread.
     *
     * Failures come back as a normal result, never an exception: on this hardware the panel leaving
     * the field mid-sequence is an ordinary outcome that Dart is expected to handle and retry.
     */
    private fun onNfcThread(result: MethodChannel.Result, work: () -> Any?) {
        nfcExecutor.execute {
            val reply = try {
                mapOf("ok" to true, "value" to work())
            } catch (e: Throwable) {
                mapOf(
                    "ok" to false,
                    "error" to "${e.javaClass.simpleName}: ${e.message ?: "no detail"}",
                )
            }
            main.post { result.success(reply) }
        }
    }

    /**
     * [tech] is `isoDep` (every panel so far) or `nfcA` — raw frames, kept for the diagnostics
     * console. Either way the session borrows the idle monitor's own connection where it can rather
     * than opening another; [busy] keeps the monitor's probe off it for the duration. See [monitor]
     * for why an ISO-DEP session must not touch NfcA.
     */
    private fun openSession(tech: String): Boolean = synchronized(tagLock) {
        val tag = currentTag ?: throw IOException("No panel on the phone.")
        val held = monitor
        if (tech == "nfcA") {
            busy = true
            val nfcA = held as? NfcA ?: run {
                // Diagnostics only: the one place that switches the tag's interface on purpose.
                runCatching { held?.close() }
                NfcA.get(tag) ?: throw IOException("This tag has no NfcA interface.")
            }
            if (!nfcA.isConnected) nfcA.connect()
            nfcA.timeout = NFCA_TIMEOUT_MS
            rawNfcA = nfcA
            return true
        }
        val dep = held as? IsoDep ?: throw IOException("This tag has no ISO-DEP interface.")

        busy = true
        dep.timeout = ISO_DEP_TIMEOUT_MS
        if (!dep.isConnected) dep.connect()
        isoDep = dep
        return true
    }

    /**
     * Every exchange is logged to `adb logcat -s epapernfc`.
     *
     * This is the project's main debugging instrument. The panel's replies are the only ground
     * truth we have about a protocol recovered by decompilation, and reading them off the device
     * beats asking anyone to transcribe hex off a phone screen.
     */
    private fun transceive(data: ByteArray): ByteArray {
        val dep = isoDep
        val nfcA = rawNfcA
        if (dep == null && nfcA == null) throw IOException("No session open.")
        android.util.Log.d(LOG_TAG, ">> ${data.joinToString(" ") { "%02X".format(it) }}")
        val response = try {
            dep?.transceive(data) ?: nfcA!!.transceive(data)
        } catch (e: Throwable) {
            android.util.Log.d(LOG_TAG, "<< ${e.javaClass.simpleName}: ${e.message}")
            throw e
        }
        android.util.Log.d(LOG_TAG, "<< ${response.joinToString(" ") { "%02X".format(it) }}")
        return response
    }

    /**
     * Hands the connection back to the monitor. An ISO-DEP session *was* the monitor's connection,
     * so it stays open as it is — closing it would cost a re-select for nothing.
     */
    private fun closeSession(): Boolean = synchronized(tagLock) {
        isoDep = null
        val raw = rawNfcA
        rawNfcA = null
        val held = monitor
        if (raw != null && raw !== held) {
            // A diagnostics NfcA session on an ISO-DEP tag: put the monitor's interface back. If the
            // panel has gone this fails, and the monitor notices on its next check — correctly.
            runCatching { raw.close() }
            runCatching { if (held != null && !held.isConnected) held.connect() }
        }
        busy = false
        return true
    }

    // ------------------------------------------------------------------------------------- reader

    private fun enableReader() {
        val adapter = nfcAdapter ?: return
        val activity = activity ?: return

        val extras = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, PRESENCE_CHECK_DELAY_MS)
        }
        adapter.enableReaderMode(
            activity,
            this,
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
                NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
            extras,
        )

        // No setDiscoveryTechnology here. It is documented as incompatible with reader mode, and in
        // AOSP's NfcActivityManager it throws while reader mode is on — but records the technology
        // *before* throwing, which then makes the next enableReaderMode throw in turn. Reader mode's
        // FLAG_READER_NFC_A already restricts polling to NFC-A.
    }

    override fun onTagDiscovered(tag: Tag) {
        discoveryCount++
        val session = sessionId.incrementAndGet()
        val nfcA = NfcA.get(tag)
        val uid = tag.id.joinToString("") { "%02X".format(it) }
        val techs = tag.techList.map { it.substringAfterLast('.') }
        val ats = IsoDep.get(tag)?.historicalBytes?.joinToString(" ") { "%02X".format(it) }

        // Identifies which protocol family a panel speaks: the (G) series exposes IsoDep, the older
        // mono panels are expected not to. Logged so it can be read straight off the device.
        android.util.Log.d(
            LOG_TAG,
            "detected uid=$uid techs=$techs " +
                "atqa=${nfcA?.atqa?.joinToString("") { "%02X".format(it) }} " +
                "sak=${nfcA?.sak?.let { "%02X".format(it) }} ats=$ats " +
                "nfcAMax=${nfcA?.maxTransceiveLength} " +
                "isoDepMax=${IsoDep.get(tag)?.maxTransceiveLength}",
        )

        emit(
            mapOf(
                "type" to "detected",
                "uid" to uid,
                "techs" to techs,
                "discoveryCount" to discoveryCount,
                "atqa" to nfcA?.atqa?.joinToString("") { "%02X".format(it) },
                "sak" to nfcA?.sak?.toInt(),
                "maxTransceiveLength" to IsoDep.get(tag)?.maxTransceiveLength,
                "ats" to ats,
            )
        )

        currentTag = tag
        // IsoDep first: it's the interface the tag is activated on. See [monitor].
        val held: TagTechnology? = IsoDep.get(tag) ?: nfcA
        if (held == null) {
            emit(mapOf("type" to "lost", "reason" to "no IsoDep or NfcA on tag", "heldMs" to 0))
            return
        }
        monitor = held

        monitoring = true
        thread(name = "nfc-presence") { holdAndMeasure(held, session) }
    }

    /**
     * Holds the connection open and reports how long it survives.
     *
     * Everything here is defensive on purpose. A tag going out of range does not fail politely with
     * one exception type — the framework throws [IOException] from the transport, but also
     * [SecurityException] ("Tag is out of date") once the handle is superseded, and binder death can
     * surface as an arbitrary unchecked throwable. On a thread of our own, any of those would take
     * the whole app down, so the loop treats every throwable as "the tag went away".
     */
    private fun holdAndMeasure(tech: TagTechnology, session: Int) {
        val startedAt = System.currentTimeMillis()
        var reason = "tag moved out of range"
        try {
            tech.connect()
            var lastProbe = System.currentTimeMillis()
            while (monitoring && sessionId.get() == session && (busy || isStillConnected(tech))) {
                emit(mapOf("type" to "held", "heldMs" to (System.currentTimeMillis() - startedAt)))
                Thread.sleep(POLL_INTERVAL_MS)
                // Stand well clear while Dart owns the tag — see [probe].
                if (!busy && System.currentTimeMillis() - lastProbe >= PROBE_INTERVAL_MS) {
                    probe(tech)
                    lastProbe = System.currentTimeMillis()
                }
            }
            if (sessionId.get() != session) reason = "superseded by a new discovery"
        } catch (e: InterruptedException) {
            reason = "interrupted"
        } catch (e: IOException) {
            // The expected, healthy path: the probe's reconnect fails because the panel has left
            // the field. Nothing is wrong, so don't surface it as though something were.
            reason = "panel moved out of range"
        } catch (e: Throwable) {
            reason = "${e.javaClass.simpleName}: ${e.message ?: "no detail"}"
        } finally {
            runCatching { tech.close() }
            // Only the newest session owns the UI, or a stale thread would report a phantom loss.
            if (sessionId.get() == session) {
                monitor = null
                currentTag = null
                emit(
                    mapOf(
                        "type" to "lost",
                        "reason" to reason,
                        "heldMs" to (System.currentTimeMillis() - startedAt),
                    )
                )
            }
        }
    }

    /**
     * Proves the panel is still in the field, and throws if it isn't.
     *
     * `isConnected` only reports a cached flag — it never touches the tag — so with the presence
     * check pushed out to a minute, nothing notices a removed panel.
     *
     * On ISO-DEP it sends [PRESENCE_PING], a command no panel implements: any answer at all, error
     * included, means the panel is there, and an exchange that fails means it isn't. It used to
     * close and reconnect instead, which deactivates and re-selects the panel every second it sits
     * on the phone. That's an experiment in itself (2026-10-10): locks were getting harder with use
     * until NFC was toggled, and those re-selects were the last regular thing the app did to the
     * radio. A tag without ISO-DEP still gets the reconnect.
     *
     * **Idle monitoring only.** Never call this while a session is open.
     */
    private fun probe(tech: TagTechnology) {
        synchronized(tagLock) {
            // A session may have opened since the caller looked; it owns the connection now.
            if (busy) return
            if (tech is IsoDep) {
                // Short, so a panel that's gone is noticed now rather than after a session's 50 s.
                tech.timeout = PING_TIMEOUT_MS
                try {
                    tech.transceive(PRESENCE_PING)
                    return
                } catch (e: IOException) {
                    // Silent isn't gone: a refresh that ran out of power leaves the panel briefly
                    // unresponsive while it's still sitting there. Declaring it lost then left the
                    // phone holding a tag the app had given up on, so nothing re-detected it until
                    // it was physically pulled away (2026-10-10). A reconnect settles it either way:
                    // it succeeds if the panel's there, and if it isn't, it fails *and* makes the
                    // platform let go, so putting the panel back is a fresh discovery.
                }
            }
            tech.close()
            tech.connect()
        }
    }

    /** `isConnected` throws rather than returning false once the handle goes stale. */
    private fun isStillConnected(tech: TagTechnology): Boolean =
        try {
            tech.isConnected
        } catch (e: Throwable) {
            false
        }

    private fun emitAdapterState() {
        val adapter = nfcAdapter
        emit(
            mapOf(
                "type" to "adapter",
                "present" to (adapter != null),
                "enabled" to (adapter?.isEnabled ?: false),
            )
        )
    }

    private fun emit(payload: Map<String, Any?>) {
        main.post { events?.success(payload) }
    }
}
