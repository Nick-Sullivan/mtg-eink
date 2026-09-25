package com.nickd.nfc_eink

import android.app.Activity
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.NfcA
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * M1: prove the panel can be discovered and *held*.
 *
 * The panel is powered parasitically by this phone's field, so the thing worth measuring is not
 * "was a tag seen" but "how long did it stay readable". Every re-entry into [onTagDiscovered]
 * while the user holds still is a dropped session — that count is the real diagnostic.
 *
 * Reader mode, never foreground dispatch: only reader mode lets us stretch the presence check,
 * skip the NDEF read at connect, and keep the platform's own tag handling out of the session.
 */
class MainActivity : FlutterActivity(), NfcAdapter.ReaderCallback {

    private companion object {
        const val EVENT_CHANNEL = "nfc_eink/tag_events"

        /**
         * The single biggest reliability lever. The platform default (~125ms) shreds a long write.
         *
         * Measured on a Pixel 10a, 2026-09-25: at 5000 the hold died at *exactly* 5 s, every time —
         * this is not a timeout to survive, it is the platform reaching in and invalidating the tag
         * handle on a cadence we choose. So it is set well beyond any plausible write duration
         * rather than merely "high". A full 2.9" transfer is expected to take seconds, not minutes.
         *
         * Cost of a large value: if the panel is physically removed, the platform won't notice for
         * this long. That is fine here — [holdAndMeasure] detects loss from the connection itself.
         */
        const val PRESENCE_CHECK_DELAY_MS = 60_000

        /** The SDK default of 700ms is too tight for a panel this slow. */
        const val TRANSCEIVE_TIMEOUT_MS = 1200

        const val POLL_INTERVAL_MS = 250L

        /** How often the idle monitor actually proves the panel is still there. See [probe]. */
        const val PROBE_INTERVAL_MS = 1000L
    }

    private var nfcAdapter: NfcAdapter? = null
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    /** Bumped on every discovery; a rising count during one hold means the session keeps dropping. */
    private var discoveryCount = 0

    /**
     * Identifies the current discovery. A re-discovery invalidates the previous [Tag] handle, so the
     * thread watching it must stand down rather than keep polling a dead object.
     */
    private val sessionId = AtomicInteger(0)

    @Volatile
    private var monitoring = false

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

        emit(
            mapOf(
                "type" to "detected",
                "uid" to uid,
                "techs" to techs,
                "discoveryCount" to discoveryCount,
                "atqa" to nfcA?.atqa?.joinToString("") { "%02X".format(it) },
                "sak" to nfcA?.sak?.toInt(),
                "maxTransceiveLength" to nfcA?.maxTransceiveLength,
            )
        )

        if (nfcA == null) {
            emit(mapOf("type" to "lost", "reason" to "no NfcA on tag", "heldMs" to 0))
            return
        }

        // transceive() blocks; it must never run on the main thread.
        monitoring = true
        thread(name = "nfc-presence") { holdAndMeasure(nfcA, session) }
    }

    /**
     * Holds the connection open and reports how long it survives. This is the M1 measurement:
     * 10+ seconds without a drop means the panel is worth writing to.
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
            nfcA.timeout = TRANSCEIVE_TIMEOUT_MS
            nfcA.connect()
            var lastProbe = System.currentTimeMillis()
            while (monitoring && sessionId.get() == session && isStillConnected(nfcA)) {
                emit(mapOf("type" to "held", "heldMs" to (System.currentTimeMillis() - startedAt)))
                Thread.sleep(POLL_INTERVAL_MS)
                if (System.currentTimeMillis() - lastProbe >= PROBE_INTERVAL_MS) {
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
     * presence check pushed out to a minute, nothing notices a removed panel. The obvious probe
     * would be a cheap transceive, but we don't know this chip's command set yet (that is M5's job)
     * and an unrecognised command could leave it in an odd state. A reconnect needs no protocol
     * knowledge at all: it fails exactly when the panel is gone.
     *
     * **Idle monitoring only.** Never call this during a write — tearing the connection down
     * mid-transfer is precisely the interruption this whole milestone exists to avoid.
     */
    private fun probe(nfcA: NfcA) {
        nfcA.close()
        nfcA.connect()
        nfcA.timeout = TRANSCEIVE_TIMEOUT_MS
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
