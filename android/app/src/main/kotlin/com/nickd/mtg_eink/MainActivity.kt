package com.nickd.mtg_eink

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.tech.NfcA
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
 */
class MainActivity : FlutterActivity(), NfcAdapter.ReaderCallback {

    private companion object {
        const val EVENT_CHANNEL = "mtg_eink/tag_events"
        const val METHOD_CHANNEL = "mtg_eink/epaper"

        /** `adb logcat -s mtgeink` gives a full APDU trace. */
        const val LOG_TAG = "mtgeink"

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

        /** Only used by the idle monitor's NfcA connection, not by the protocol. */
        const val NFCA_TIMEOUT_MS = 1200

        const val POLL_INTERVAL_MS = 250L

        /** How often the idle monitor actually proves the panel is still there. See [probe]. */
        const val PROBE_INTERVAL_MS = 1000L
    }

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

    @Volatile
    private var currentNfcA: NfcA? = null

    @Volatile
    private var currentTag: Tag? = null

    /** The open ISO-DEP channel, if Dart has a session running. */
    @Volatile
    private var isoDep: IsoDep? = null

    /**
     * Set while Dart owns the tag. The idle monitor's [probe] tears the connection down and rebuilds
     * it, which mid-transfer is exactly the interruption this project exists to avoid.
     */
    @Volatile
    private var busy = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openSession" -> onNfcThread(result) { openSession() }
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

    private fun openSession(): Boolean {
        val tag = currentTag ?: throw IOException("No panel on the phone.")
        val dep = IsoDep.get(tag) ?: throw IOException("This tag has no ISO-DEP interface.")

        busy = true
        // The idle monitor holds an NfcA connection open; a second connect on a tag we already hold
        // fails. Release it before ISO-DEP takes over.
        runCatching { currentNfcA?.close() }

        dep.timeout = ISO_DEP_TIMEOUT_MS
        if (!dep.isConnected) dep.connect()
        isoDep = dep
        return true
    }

    /**
     * Every exchange is logged to `adb logcat -s mtgeink`.
     *
     * This is the project's main debugging instrument. The panel's replies are the only ground
     * truth we have about a protocol recovered by decompilation, and reading them off the device
     * beats asking anyone to transcribe hex off a phone screen.
     */
    private fun transceive(data: ByteArray): ByteArray {
        val dep = isoDep ?: throw IOException("No session open.")
        android.util.Log.d(LOG_TAG, ">> ${data.joinToString(" ") { "%02X".format(it) }}")
        val response = try {
            dep.transceive(data)
        } catch (e: Throwable) {
            android.util.Log.d(LOG_TAG, "<< ${e.javaClass.simpleName}: ${e.message}")
            throw e
        }
        android.util.Log.d(LOG_TAG, "<< ${response.joinToString(" ") { "%02X".format(it) }}")
        return response
    }

    private fun closeSession(): Boolean {
        runCatching { isoDep?.close() }
        isoDep = null
        // Give the monitor its connection back. If the panel has gone this fails, and the monitor
        // notices on its next check — which is correct.
        runCatching {
            currentNfcA?.connect()
            currentNfcA?.timeout = NFCA_TIMEOUT_MS
        }
        busy = false
        return true
    }

    override fun onResume() {
        super.onResume()
        val adapter = nfcAdapter ?: return

        val extras = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, PRESENCE_CHECK_DELAY_MS)
        }
        adapter.enableReaderMode(
            this,
            this,
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
                NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
            extras,
        )

        // API 35+: stop the controller cycling through poll technologies we don't use and drop the
        // card-emulation listen slots, so the field stays devoted to NFC-A. Adds no power; wastes less.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            runCatching {
                adapter.setDiscoveryTechnology(
                    this as Activity,
                    NfcAdapter.FLAG_READER_NFC_A,
                    NfcAdapter.FLAG_LISTEN_DISABLE,
                )
            }
        }

        emitAdapterState()
    }

    override fun onPause() {
        super.onPause()
        monitoring = false
        runCatching { isoDep?.close() }
        isoDep = null
        val adapter = nfcAdapter ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            runCatching { adapter.resetDiscoveryTechnology(this as Activity) }
        }
        adapter.disableReaderMode(this)
    }

    override fun onTagDiscovered(tag: Tag) {
        discoveryCount++
        val session = sessionId.incrementAndGet()
        val nfcA = NfcA.get(tag)
        val uid = tag.id.joinToString("") { "%02X".format(it) }
        val techs = tag.techList.map { it.substringAfterLast('.') }
        val ats = IsoDep.get(tag)?.historicalBytes?.joinToString(" ") { "%02X".format(it) }

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
        if (nfcA == null) {
            emit(mapOf("type" to "lost", "reason" to "no NfcA on tag", "heldMs" to 0))
            return
        }
        currentNfcA = nfcA

        monitoring = true
        thread(name = "nfc-presence") { holdAndMeasure(nfcA, session) }
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
    private fun holdAndMeasure(nfcA: NfcA, session: Int) {
        val startedAt = System.currentTimeMillis()
        var reason = "tag moved out of range"
        try {
            nfcA.timeout = NFCA_TIMEOUT_MS
            nfcA.connect()
            var lastProbe = System.currentTimeMillis()
            while (monitoring && sessionId.get() == session && (busy || isStillConnected(nfcA))) {
                emit(mapOf("type" to "held", "heldMs" to (System.currentTimeMillis() - startedAt)))
                Thread.sleep(POLL_INTERVAL_MS)
                // Stand well clear while Dart owns the tag — see [probe].
                if (!busy && System.currentTimeMillis() - lastProbe >= PROBE_INTERVAL_MS) {
                    probe(nfcA)
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
            runCatching { nfcA.close() }
            // Only the newest session owns the UI, or a stale thread would report a phantom loss.
            if (sessionId.get() == session) {
                currentNfcA = null
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
     * [NfcA.isConnected] only reports a cached flag — it never touches the tag — so with the
     * presence check pushed out to a minute, nothing notices a removed panel. A reconnect needs no
     * protocol knowledge at all: it fails exactly when the panel is gone.
     *
     * **Idle monitoring only.** Never call this while a session is open.
     */
    private fun probe(nfcA: NfcA) {
        nfcA.close()
        nfcA.connect()
        nfcA.timeout = NFCA_TIMEOUT_MS
    }

    /** [NfcA.isConnected] throws rather than returning false once the handle goes stale. */
    private fun isStillConnected(nfcA: NfcA): Boolean =
        try {
            nfcA.isConnected
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
