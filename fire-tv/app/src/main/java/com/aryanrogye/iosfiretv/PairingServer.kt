package com.aryanrogye.iosfiretv

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class PairingServer(
    context: Context,
    private val listener: Listener,
) {
    interface Listener {
        fun onPairingCode(code: String)
        fun onPairingRequest(deviceName: String?)
        fun onStatus(message: String, streaming: Boolean)
        fun onVideoConfiguration(
            width: Int,
            height: Int,
            rotationDegrees: Int,
            sps: ByteArray,
            pps: ByteArray,
        )
        fun onVideoFrame(data: ByteArray, timestampMilliseconds: Long, keyFrame: Boolean)
        fun onAudioConfiguration(sampleRate: Int, channels: Int)
        fun onAudioFrame(pcm: ByteArray)
        fun onMediaEnded()
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val running = AtomicBoolean(false)
    private val resetRequested = AtomicBoolean(false)
    private val random = SecureRandom()
    @Volatile
    private var clientSocket: Socket? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    @Volatile
    private var resolvedMac: InetSocketAddress? = null
    private val connecting = AtomicBoolean(false)
    @Volatile
    private lateinit var pairingCode: String

    fun start() {
        if (!running.compareAndSet(false, true)) return

        rotatePairingCode()

        listener.onStatus("Looking for a Mac…", false)
        discoverMacSender()
    }

    fun reset() {
        if (!running.get()) return

        val activeClient = clientSocket
        if (activeClient != null) {
            resetRequested.set(true)
            runCatching { activeClient.close() }
        }
        rotatePairingCode()
        listener.onStatus("Ready to pair — session reset", false)
    }

    fun stop() {
        running.set(false)
        runCatching { clientSocket?.close() }
        discoveryListener?.let { runCatching { nsdManager.stopServiceDiscovery(it) } }
        discoveryListener = null
        executor.shutdownNow()
    }

    private fun handleClient(socket: Socket) {
        socket.tcpNoDelay = true
        socket.soTimeout = 15_000
        val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
        val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))

        try {
            listener.onPairingRequest(null)
            val salt = randomBytes(16)
            val serverChallenge = randomBytes(32)
            writeJson(
                output,
                JSONObject()
                    .put("type", "hello")
                    .put("version", 1)
                    .put("salt", encode(salt))
                    .put("challenge", encode(serverChallenge)),
            )

            val auth = readJson(input)
            require(auth.optString("type") == "auth") { "Expected authentication" }
            val deviceName = auth.optString("name").trim().takeIf { it.isNotEmpty() }
            Log.i(TAG, "authentication request from ${deviceName ?: "unknown device"}")
            listener.onPairingRequest(deviceName)
            val clientChallenge = decode(auth.getString("challenge"))
            val suppliedProof = decode(auth.getString("proof"))
            require(clientChallenge.size == 32) { "Invalid challenge" }

            val key = deriveKey(pairingCode, salt)
            val expectedProof = hmac(
                key,
                "client".toByteArray(StandardCharsets.UTF_8),
                serverChallenge,
                clientChallenge,
            )
            if (!MessageDigest.isEqual(suppliedProof, expectedProof)) {
                Log.w(TAG, "authentication rejected for ${deviceName ?: "unknown device"}")
                writeJson(output, JSONObject().put("type", "auth_failed"))
                listener.onStatus("Incorrect pairing code", false)
                return
            }

            val serverProof = hmac(
                key,
                "server".toByteArray(StandardCharsets.UTF_8),
                serverChallenge,
                clientChallenge,
            )
            writeJson(
                output,
                JSONObject()
                    .put("type", "auth_ok")
                    .put("proof", encode(serverProof)),
            )

            socket.soTimeout = 0
            Log.i(TAG, "authentication succeeded for ${deviceName ?: "unknown device"}")
            listener.onStatus("Streaming display and audio", true)
            readMedia(input, key)
        } catch (_: java.io.EOFException) {
            // Normal disconnect.
        } catch (error: Exception) {
            if (running.get() && !resetRequested.get()) {
                listener.onStatus("Connection ended: ${error.message ?: "unknown"}", false)
            }
        } finally {
            listener.onMediaEnded()
            runCatching { socket.close() }
        }
    }

    private fun readMedia(input: DataInputStream, key: ByteArray) {
        while (running.get()) {
            val length = input.readInt()
            require(length in 14..MAX_FRAME_PACKET_BYTES) { "Invalid frame size" }
            val packetType = input.readUnsignedByte()
            val payload = ByteArray(length - 1)
            input.readFully(payload)
            if (packetType != PACKET_ENCRYPTED_MEDIA) continue

            val plaintext = decrypt(payload, key)
            require(plaintext.size >= MEDIA_HEADER_BYTES && plaintext[0].toInt() == MEDIA_VERSION) {
                "Invalid media packet"
            }
            val kind = plaintext[1].toInt()
            val timestamp = ByteBuffer.wrap(plaintext, 2, 8)
                .order(ByteOrder.BIG_ENDIAN)
                .long
            val keyFrame = plaintext[10].toInt() != 0
            val media = plaintext.copyOfRange(MEDIA_HEADER_BYTES, plaintext.size)
            when (kind) {
                MEDIA_VIDEO_CONFIGURATION -> parseVideoConfiguration(media)
                MEDIA_VIDEO_FRAME -> listener.onVideoFrame(media, timestamp, keyFrame)
                MEDIA_AUDIO_CONFIGURATION -> parseAudioConfiguration(media)
                MEDIA_AUDIO_FRAME -> listener.onAudioFrame(media)
            }
        }
    }

    private fun parseVideoConfiguration(data: ByteArray) {
        val input = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        require(input.remaining() >= 10) { "Invalid video configuration" }
        val width = input.short.toInt() and 0xffff
        val height = input.short.toInt() and 0xffff
        val rotation = input.short.toInt() and 0xffff
        val spsSize = input.short.toInt() and 0xffff
        require(spsSize in 1..input.remaining()) { "Invalid SPS" }
        val sps = ByteArray(spsSize).also(input::get)
        require(input.remaining() >= 2) { "Missing PPS" }
        val ppsSize = input.short.toInt() and 0xffff
        require(ppsSize in 1..input.remaining()) { "Invalid PPS" }
        val pps = ByteArray(ppsSize).also(input::get)
        Log.d(TAG, "received video config ${width}x$height rotation=$rotation sps=$spsSize pps=$ppsSize")
        listener.onVideoConfiguration(width, height, rotation, sps, pps)
    }

    private fun parseAudioConfiguration(data: ByteArray) {
        val input = ByteBuffer.wrap(data).order(ByteOrder.BIG_ENDIAN)
        require(input.remaining() >= 6) { "Invalid audio configuration" }
        val sampleRate = input.int
        val channels = input.get().toInt() and 0xff
        val encoding = input.get().toInt() and 0xff
        require(sampleRate in 8_000..192_000 && channels in 1..2 && encoding == AUDIO_PCM_16) {
            "Unsupported audio configuration"
        }
        listener.onAudioConfiguration(sampleRate, channels)
    }

    private fun discoverMacSender() {
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!running.get() || serviceInfo.serviceType != MAC_SERVICE_TYPE) return
                nsdManager.resolveService(
                    serviceInfo,
                    object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                            Log.w(TAG, "could not resolve Mac sender: $errorCode")
                        }

                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            val endpoint = InetSocketAddress(serviceInfo.host, serviceInfo.port)
                            resolvedMac = endpoint
                            connectToMac(endpoint)
                        }
                    },
                )
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                resolvedMac = null
            }

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                listener.onStatus("Mac discovery unavailable ($errorCode)", false)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        discoveryListener = discovery
        nsdManager.discoverServices(MAC_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    private fun connectToMac(endpoint: InetSocketAddress) {
        if (!running.get() || !connecting.compareAndSet(false, true)) return
        executor.execute {
            var connected = false
            try {
                listener.onStatus("Connecting to ${endpoint.hostString}…", false)
                val socket = Socket().apply {
                    reuseAddress = true
                    tcpNoDelay = true
                    receiveBufferSize = 512 * 1024
                    connect(endpoint, CONNECT_TIMEOUT_MS)
                }
                connected = true
                clientSocket = socket
                Log.i(TAG, "connected to Mac at $endpoint")
                handleClient(socket)
            } catch (error: Exception) {
                if (running.get()) {
                    Log.w(TAG, "Mac connection failed", error)
                    listener.onStatus("Waiting for the Mac…", false)
                }
            } finally {
                clientSocket = null
                connecting.set(false)
                if (connected && running.get()) {
                    if (!resetRequested.getAndSet(false)) rotatePairingCode()
                    listener.onStatus("Looking for a Mac…", false)
                }
                if (running.get() && resolvedMac == endpoint) {
                    executor.execute {
                        runCatching { Thread.sleep(RECONNECT_DELAY_MS) }
                        connectToMac(endpoint)
                    }
                }
            }
        }
    }

    private fun writeJson(output: DataOutputStream, json: JSONObject) {
        val jsonBytes = json.toString().toByteArray(StandardCharsets.UTF_8)
        output.writeInt(jsonBytes.size + 1)
        output.writeByte(PACKET_JSON)
        output.write(jsonBytes)
        output.flush()
    }

    private fun readJson(input: DataInputStream): JSONObject {
        val length = input.readInt()
        require(length in 2..MAX_JSON_PACKET_BYTES) { "Invalid message size" }
        require(input.readUnsignedByte() == PACKET_JSON) { "Expected JSON message" }
        val bytes = ByteArray(length - 1)
        input.readFully(bytes)
        return JSONObject(String(bytes, StandardCharsets.UTF_8))
    }

    private fun decrypt(payload: ByteArray, key: ByteArray): ByteArray {
        require(payload.size > GCM_NONCE_BYTES + 16) { "Encrypted frame is too short" }
        val nonce = payload.copyOfRange(0, GCM_NONCE_BYTES)
        val ciphertext = payload.copyOfRange(GCM_NONCE_BYTES, payload.size)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, nonce),
            )
            doFinal(ciphertext)
        }
    }

    private fun deriveKey(code: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(code.toCharArray(), salt, PBKDF2_ITERATIONS, 256)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    private fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            parts.forEach { update(it) }
            doFinal()
        }

    private fun rotatePairingCode() {
        pairingCode = "%06d".format(random.nextInt(1_000_000))
        listener.onPairingCode(pairingCode)
    }

    private fun randomBytes(count: Int) = ByteArray(count).also(random::nextBytes)
    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)

    private companion object {
        const val TAG = "FireTVProtocol"
        const val MAC_SERVICE_TYPE = "_framesmac._tcp."
        const val PACKET_JSON = 0
        const val STREAM_PORT = 49_218
        const val CONNECT_TIMEOUT_MS = 5_000
        const val RECONNECT_DELAY_MS = 1_500L
        const val PACKET_ENCRYPTED_MEDIA = 2
        const val MEDIA_VERSION = 2
        const val MEDIA_HEADER_BYTES = 11
        const val MEDIA_VIDEO_CONFIGURATION = 1
        const val MEDIA_VIDEO_FRAME = 2
        const val MEDIA_AUDIO_CONFIGURATION = 3
        const val MEDIA_AUDIO_FRAME = 4
        const val AUDIO_PCM_16 = 1
        const val GCM_NONCE_BYTES = 12
        const val PBKDF2_ITERATIONS = 120_000
        const val MAX_JSON_PACKET_BYTES = 64 * 1024
        const val MAX_FRAME_PACKET_BYTES = 8 * 1024 * 1024
    }
}
