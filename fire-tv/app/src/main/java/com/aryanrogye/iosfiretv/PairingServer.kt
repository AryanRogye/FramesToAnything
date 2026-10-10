package com.aryanrogye.iosfiretv

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import org.json.JSONArray
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID
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
        fun onMacsChanged(macs: List<MacServer>)
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
        fun onAudioConfiguration(sampleRate: Int, channels: Int, encoding: Int, codecConfig: ByteArray)
        fun onAudioFrame(data: ByteArray, timestampMilliseconds: Long)
        fun onCaption(id: String, revision: Long, startMs: Long, endMs: Long, text: String, final: Boolean, committedText: String?, partialText: String?)
        fun onRemoteSeekResult(requestID: String, command: String, status: String)
        fun onMediaEnded()
    }

    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val running = AtomicBoolean(false)
    private val random = SecureRandom()
    @Volatile
    private var clientSocket: Socket? = null
    @Volatile
    private var serverSocket: ServerSocket? = null
    @Volatile
    private var activeOutput: DataOutputStream? = null
    private var controlAuthentication: ReceiverControlAuthentication? = null
    @Volatile
    private var negotiatedFeatures: Set<String> = emptySet()
    private val outputLock = Any()
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private val coordinator = Executors.newSingleThreadScheduledExecutor()
    private val policy = MacConnectionPolicy()
    private data class DiscoveredMac(val service: NsdServiceInfo, val id: String, val name: String,
                                     val endpoint: InetSocketAddress, val lastSeen: Long)
    private val macs = linkedMapOf<String, DiscoveredMac>()
    private val services = linkedMapOf<String, NsdServiceInfo>()
    private val lostServices = mutableSetOf<String>()
    private val serviceIDs = mutableMapOf<String, String>()
    private val serviceVersions = mutableMapOf<String, Long>()
    private val resolveQueue = ArrayDeque<Pair<String, Long>>()
    private var resolving = false
    private var resolveToken = 0L
    private var resolveDeadline: ScheduledFuture<*>? = null
    private var discoveryFailures = 0
    private val controlWriter = Executors.newSingleThreadExecutor()
    private val controlWritePending = AtomicBoolean(false)
    private var discoveryGeneration = 0L
    private var retry: ScheduledFuture<*>? = null
    private var discoveryRetry: ScheduledFuture<*>? = null
    private var discoveryRefresh: ScheduledFuture<*>? = null
    private var heartbeat: ScheduledFuture<*>? = null
    private var mediaDeadline: ScheduledFuture<*>? = null
    private var pendingSelection: String? = null
    private var activeToken: Long? = null
    private val connectivity = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private class PairingRequired(message: String) : Exception(message)
    @Volatile
    private lateinit var pairingCode: String
    private val receiverID: String = preferences.getString(RECEIVER_ID_KEY, null)
        ?: UUID.randomUUID().toString().lowercase().also {
            preferences.edit().putString(RECEIVER_ID_KEY, it).apply()
        }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        coordinator.execute {
            rotatePairingCode()
            acceptDirectSenders() // compatibility for the separate iOS sender
            advertiseReceiver()
            listener.onStatus("Choose a Mac and press Connect", false)
            discoverMacSender()
            discoveryRefresh = coordinator.scheduleWithFixedDelay({
                if (running.get()) restartDiscovery()
            }, 30, 30, TimeUnit.SECONDS)
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = networkChanged()
                override fun onLost(network: Network) = networkChanged()
            }
            networkCallback = callback
            runCatching { connectivity.registerDefaultNetworkCallback(callback) }
        }
    }

    private fun networkChanged() {
        post {
            restartDiscovery()
            if (policy.wantsConnection && activeToken == null) scheduleRetry(0)
        }
    }

    private fun post(action: () -> Unit) {
        if (!running.get()) return
        runCatching { coordinator.execute { if (running.get()) action() } }
    }

    fun connect(macID: String) = post {
        retry?.cancel(false)
        pendingSelection = macID
        policy.disconnect()
        clientSocket?.let { runCatching { it.close() } }
        if (activeToken == null) startSelection()
    }

    private fun startSelection() {
        val id = pendingSelection ?: return
        pendingSelection = null
        policy.select(id)
        attemptSelectedMac()
    }

    fun disconnect() = post {
        pendingSelection = null
        policy.disconnect()
        retry?.cancel(false)
        heartbeat?.cancel(false)
        clientSocket?.let { runCatching { it.close() } }
        listener.onStatus("Disconnected — choose a Mac to connect", false)
    }

    fun reset() {
        disconnect()
        post { rotatePairingCode() }
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        runCatching { clientSocket?.close() }
        runCatching { serverSocket?.close() }
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        coordinator.execute {
            policy.disconnect(stop = true)
            retry?.cancel(false)
            heartbeat?.cancel(false)
            mediaDeadline?.cancel(false)
            discoveryRetry?.cancel(false)
            discoveryRefresh?.cancel(false)
            discoveryListener?.let { runCatching { nsdManager.stopServiceDiscovery(it) } }
            discoveryListener = null
            registrationListener?.let { runCatching { nsdManager.unregisterService(it) } }
            registrationListener = null
            resolveDeadline?.cancel(false)
            controlWriter.shutdownNow()
            executor.shutdownNow()
        }
        coordinator.shutdown()
    }

    private fun handleClient(socket: Socket, token: Long, expectedSenderID: String? = null): Boolean {
        var pairingRequired = false
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
                    .put("receiverID", receiverID)
                    .put(
                        "features",
                        JSONArray()
                            .put(RemoteMediaCommand.SEEK_FEATURE)
                            .put(FEATURE_HEARTBEAT)
                            .put(FEATURE_LIVE_CAPTIONS)
                            .put(FEATURE_CINEMA_BUFFER)
                            .put(FEATURE_RECEIVER_REPORTS)
                            .put(FEATURE_KEYFRAME_REQUEST)
                            .put(ReceiverControlAuthentication.FEATURE)
                            // Raw AAC in this protocol carries no encoder-delay
                            // or trim metadata. The Mac assigns input PCM PTS to
                            // primed AAC output, so decoded sound can lag video
                            // even with a correct device clock. Negotiate PCM
                            // until AAC priming is represented end to end.
                            .put(FEATURE_REMOTE_MEDIA_CONTROLS),
                    )
                    .put("salt", encode(salt))
                    .put("challenge", encode(serverChallenge)),
            )

            val auth = readJson(input)
            if (auth.optString("type") == "pairing_required") throw PairingRequired("Enter the TV code on the Mac, then press Connect again")
            require(auth.optString("type") == "auth") { "Expected authentication" }
            val deviceName = auth.optString("name").trim().takeIf { it.isNotEmpty() }
            val senderID = auth.optString("senderID").trim().takeIf { it.isNotEmpty() }
            require(expectedSenderID == null || senderID == expectedSenderID) { "Mac identity changed" }
            val mode = auth.optString("mode", "code")
            val requestedFeatures = buildSet {
                val values = auth.optJSONArray("acceptedFeatures")
                if (values != null) {
                    for (index in 0 until values.length()) {
                        values.optString(index).takeIf { it.isNotEmpty() }?.let(::add)
                    }
                }
            }
            negotiatedFeatures = requestedFeatures.intersect(SUPPORTED_FEATURES)
            if (!negotiatedFeatures.contains(ReceiverControlAuthentication.FEATURE)) {
                negotiatedFeatures = negotiatedFeatures - FEATURE_HEARTBEAT
            }
            Log.i("FramesCaptions", "negotiated=${negotiatedFeatures.contains(FEATURE_LIVE_CAPTIONS)}")
            Log.i(TAG, "authentication request from ${deviceName ?: "unknown device"}")
            listener.onPairingRequest(deviceName)
            val clientChallenge = decode(auth.getString("challenge"))
            val suppliedProof = decode(auth.getString("proof"))
            require(clientChallenge.size == 32) { "Invalid challenge" }

            val key = when (mode) {
                "remembered" -> senderID
                    ?.let(::loadTrustedSender)
                    ?.let { deriveRememberedSessionKey(it, salt, serverChallenge, clientChallenge) }
                "code" -> deriveKey(pairingCode, salt)
                else -> null
            }
            if (key == null) {
                writeJson(
                    output,
                    JSONObject()
                        .put("type", "auth_failed")
                        .put("reason", if (mode == "remembered") "forgotten" else "code"),
                )
                listener.onStatus(
                    if (mode == "remembered") "This Mac needs to pair again" else "Incorrect pairing code",
                    false,
                )
                throw PairingRequired("This Mac needs to pair again")
            }
            val expectedProof = hmac(
                key,
                "client".toByteArray(StandardCharsets.UTF_8),
                serverChallenge,
                clientChallenge,
            )
            if (!MessageDigest.isEqual(suppliedProof, expectedProof)) {
                Log.w(TAG, "authentication rejected for ${deviceName ?: "unknown device"}")
                writeJson(
                    output,
                    JSONObject()
                        .put("type", "auth_failed")
                        .put("reason", if (mode == "remembered") "forgotten" else "code"),
                )
                listener.onStatus(
                    if (mode == "remembered") "This Mac needs to pair again" else "Incorrect pairing code",
                    false,
                )
                throw PairingRequired("Pairing was not accepted — enter the current code on the Mac")
            }

            if (mode == "code" && senderID != null) {
                saveTrustedSender(
                    senderID,
                    deriveTrustSecret(key, serverChallenge, clientChallenge),
                )
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
                    .put("proof", encode(serverProof))
                    .put("acceptedFeatures", JSONArray(negotiatedFeatures.toList().sorted())),
            )

            socket.soTimeout = if (negotiatedFeatures.contains(FEATURE_HEARTBEAT)) 12_000 else 0
            synchronized(outputLock) {
                controlAuthentication = ReceiverControlAuthentication(key, serverChallenge, clientChallenge)
                activeOutput = output
            }
            Log.i(TAG, "authentication succeeded for ${deviceName ?: "unknown device"}")
            post {
                if (activeToken == token && clientSocket === socket) {
                    if (policy.transition(token, MacConnectionPolicy.State.AUTHENTICATING,
                                          MacConnectionPolicy.State.AWAITING_MEDIA)) {
                        listener.onStatus("Connected — waiting for Mac capture…", false)
                    }
                    publishMacs()
                    mediaDeadline = coordinator.schedule({
                        if (activeToken == token && policy.state == MacConnectionPolicy.State.AWAITING_MEDIA) {
                            runCatching { socket.close() }
                        }
                    }, 120, TimeUnit.SECONDS)
                    if (negotiatedFeatures.contains(FEATURE_HEARTBEAT)) {
                        heartbeat = coordinator.scheduleWithFixedDelay({
                            if (activeToken == token && clientSocket === socket) {
                                sendHeartbeat()
                            }
                        }, 0, 2, TimeUnit.SECONDS)
                    }
                }
            }
            readMedia(input, key, socket, token)
        } catch (error: PairingRequired) {
            pairingRequired = true
            post { if (activeToken == token) listener.onStatus(error.message ?: "Pairing required", false) }
        } catch (_: java.io.EOFException) {
            // Normal disconnect.
        } catch (error: Exception) {
            if (running.get()) {
                listener.onStatus("Connection ended: ${error.message ?: "unknown"}", false)
            }
        } finally {
            // Close before taking the write lock: a blocked control write must
            // be interrupted before cleanup can acquire that lock.
            runCatching { socket.close() }
            synchronized(outputLock) {
                if (activeOutput === output) {
                    activeOutput = null
                    controlAuthentication = null
                }
            }
            negotiatedFeatures = emptySet()
            if (running.get()) listener.onMediaEnded()
            runCatching { socket.close() }
        }
        return pairingRequired
    }

    private fun acceptDirectSenders() {
        executor.execute {
            try {
                val server = ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(STREAM_PORT))
                }
                if (!running.get()) { server.close(); return@execute }
                serverSocket = server
                while (running.get()) {
                    val socket = server.accept()
                    if (!running.get()) { socket.close(); break }
                    post {
                        if (activeToken != null || policy.wantsConnection || pendingSelection != null) {
                            socket.close()
                        } else {
                            val token = -System.nanoTime()
                            activeToken = token
                            clientSocket = socket
                            runSession(socket, token, null)
                        }
                    }
                }
            } catch (error: Exception) {
                if (running.get()) Log.w(TAG, "iOS compatibility listener unavailable", error)
            }
        }
    }

    private fun readMedia(input: DataInputStream, key: ByteArray, socket: Socket, token: Long) {
        var receivedVideo = false
        while (running.get() && clientSocket === socket) {
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
            if (kind == MEDIA_REMOTE_SEEK_RESULT && negotiatedFeatures.contains(RemoteMediaCommand.SEEK_FEATURE)) {
                if (plaintext.size <= MEDIA_HEADER_BYTES + 1024) runCatching {
                    val result = JSONObject(String(plaintext.copyOfRange(MEDIA_HEADER_BYTES, plaintext.size), Charsets.UTF_8))
                    listener.onRemoteSeekResult(result.getString("requestID"), result.getString("command"), result.getString("status"))
                }
                continue
            }
            if (kind == MEDIA_HEARTBEAT) continue
            if (kind == MEDIA_VIDEO_FRAME && !receivedVideo) {
                receivedVideo = true
                post {
                    if (activeToken == token && clientSocket === socket &&
                        (token < 0 || policy.transition(token, MacConnectionPolicy.State.AWAITING_MEDIA,
                                                       MacConnectionPolicy.State.STREAMING))) {
                        mediaDeadline?.cancel(false)
                        policy.healthy(token)
                        listener.onStatus("Streaming display and audio", true)
                    }
                }
            }
            val timestamp = ByteBuffer.wrap(plaintext, 2, 8)
                .order(ByteOrder.BIG_ENDIAN)
                .long
            val keyFrame = plaintext[10].toInt() != 0
            val media = plaintext.copyOfRange(MEDIA_HEADER_BYTES, plaintext.size)
            when (kind) {
                MEDIA_VIDEO_CONFIGURATION -> parseVideoConfiguration(media)
                MEDIA_VIDEO_FRAME -> listener.onVideoFrame(media, timestamp, keyFrame)
                MEDIA_AUDIO_CONFIGURATION -> parseAudioConfiguration(media)
                MEDIA_AUDIO_FRAME -> listener.onAudioFrame(media, timestamp)
                MEDIA_CAPTION -> if (negotiatedFeatures.contains(FEATURE_LIVE_CAPTIONS)) {
                    // A malformed optional caption must never tear down working media.
                    if (media.size <= 2048) runCatching {
                        val cue = JSONObject(String(media, Charsets.UTF_8))
                        val end = cue.getLong("endMs")
                        val text = cue.getString("text")
                        if (timestamp >= 0 && end >= timestamp && end - timestamp <= 10_000 &&
                            text.isNotBlank() && text.length <= 600) {
                            val id = cue.optString("id", timestamp.toString()).take(64)
                            val revision = cue.optLong("revision", 0)
                            Log.i("FramesCaptions", "received id=$id revision=$revision")
                            val committed = if (cue.has("committedText")) cue.getString("committedText") else null
                            val partial = if (cue.has("partialText")) cue.getString("partialText") else null
                            if ((committed?.length ?: 0) <= 600 && (partial?.length ?: 0) <= 600) {
                                listener.onCaption(id, revision, timestamp, end, text, cue.optBoolean("final"), committed, partial)
                            }
                        }
                    }
                }
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
        require(
            sampleRate in 8_000..192_000 && channels in 1..2 &&
                (encoding == AUDIO_PCM_16 || encoding == AUDIO_AAC_LC) &&
                (encoding == AUDIO_PCM_16 || input.remaining() > 0)
        ) {
            "Unsupported audio configuration"
        }
        val codecConfig = ByteArray(input.remaining()).also(input::get)
        listener.onAudioConfiguration(sampleRate, channels, encoding, codecConfig)
    }

    fun sendReceiverReport(report: CinemaPlaybackReport) {
        if (!negotiatedFeatures.contains(FEATURE_RECEIVER_REPORTS)) return
        val output = activeOutput ?: return
        val message = JSONObject()
            .put("type", "receiver_report")
            .put("version", 1)
            .put("videoBufferMs", report.videoBufferMilliseconds)
            .put("audioBufferMs", report.audioBufferMilliseconds)
            .put("targetBufferMs", report.targetBufferMilliseconds)
            .put("decoderBacklogMs", report.decoderBacklogMilliseconds)
            .put("underruns", report.underruns)
            .put("recoveries", report.recoveries)
            .put("lastPresentedTimestampMs", report.lastPresentedTimestampMilliseconds)
        enqueueControl(output, message)
    }

    fun requestKeyFrame(reason: String, lastPresentedTimestampMilliseconds: Long) {
        if (!negotiatedFeatures.contains(FEATURE_KEYFRAME_REQUEST)) return
        val output = activeOutput ?: return
        val message = JSONObject()
            .put("type", "request_keyframe")
            .put("version", 1)
            .put("reason", reason)
            .put("lastPresentedTimestampMs", lastPresentedTimestampMilliseconds)
        enqueueControl(output, message)
    }

    fun sendRemoteMediaCommand(command: String, requestID: String? = null): Boolean {
        if (!negotiatedFeatures.contains(FEATURE_REMOTE_MEDIA_CONTROLS) ||
            !RemoteMediaCommand.allowed(command, negotiatedFeatures.contains(RemoteMediaCommand.SEEK_FEATURE))) return false
        if (RemoteMediaCommand.isSeek(command) && requestID == null) return false
        val output = activeOutput ?: return false
        val message = JSONObject()
            .put("type", "remote_media_command")
            .put("version", 1)
            .put("command", command)
        requestID?.let { message.put("requestID", it) }
        Log.i(TAG, "remote media command=$command")
        return enqueueControl(output, message)
    }

    private fun writeControl(output: DataOutputStream, message: JSONObject) {
        if (activeOutput !== output ||
            !negotiatedFeatures.contains(ReceiverControlAuthentication.FEATURE)) return
        val signer = controlAuthentication ?: return
        val payload = message.toString().toByteArray(StandardCharsets.UTF_8)
        val (sequence, proof) = signer.next(payload)
        writeJson(output, JSONObject()
            .put("type", "authenticated_control")
            .put("sequence", sequence.toString())
            .put("payload", encode(payload))
            .put("proof", encode(proof)))
    }

    private fun isAvailable(mac: DiscoveredMac): Boolean =
        serviceIDs[mac.service.serviceName] == mac.id && MacDiscoveryAvailability.available(
            servicePresent = services.containsKey(mac.service.serviceName),
            explicitlyLost = mac.service.serviceName in lostServices,
            lastSeen = mac.lastSeen, now = SystemClock.elapsedRealtime()
        )

    private fun publishMacs() {
        val list = macs.values.map {
            MacServer(it.id, it.name, isAvailable(it),
                      loadTrustedSender(it.id) != null)
        }.sortedBy { it.name.lowercase() }
        listener.onMacsChanged(list)
    }

    private fun restartDiscovery() {
        discoveryGeneration++
        discoveryListener?.let { runCatching { nsdManager.stopServiceDiscovery(it) } }
        discoveryListener = null
        services.clear()
        serviceVersions.clear()
        resolveQueue.clear()
        // Do not overlap old and new resolveService calls on older Fire OS.
        publishMacs()
        discoveryRetry?.cancel(false)
        discoveryRetry = coordinator.schedule({
            if (running.get() && discoveryListener == null) discoverMacSender()
        }, (500L shl discoveryFailures.coerceAtMost(5)).coerceAtMost(15_000), TimeUnit.MILLISECONDS)
    }

    private fun discoverMacSender() {
        if (!running.get() || discoveryListener != null) return
        val generation = ++discoveryGeneration
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = post {
                if (generation == discoveryGeneration) discoveryFailures = 0
            }
            override fun onServiceFound(serviceInfo: NsdServiceInfo) = post {
                if (generation != discoveryGeneration || serviceInfo.serviceType != MAC_SERVICE_TYPE) return@post
                val name = serviceInfo.serviceName
                services[name] = serviceInfo
                lostServices.remove(name)
                val version = (serviceVersions[name] ?: 0) + 1
                serviceVersions[name] = version
                resolveQueue.add(name to version)
                resolveNext()
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = post {
                if (generation != discoveryGeneration) return@post
                services.remove(serviceInfo.serviceName)
                lostServices.add(serviceInfo.serviceName)
                serviceVersions[serviceInfo.serviceName] = (serviceVersions[serviceInfo.serviceName] ?: 0) + 1
                publishMacs()
            }
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = post {
                if (generation == discoveryGeneration) {
                    discoveryFailures++
                    Log.w(TAG, "Mac discovery failed: $errorCode")
                    restartDiscovery()
                }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        discoveryListener = discovery
        try {
            nsdManager.discoverServices(MAC_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (error: Exception) {
            discoveryFailures++
            restartDiscovery()
        }
    }

    private fun resolveNext() {
        if (resolving || !running.get()) return
        val request = resolveQueue.removeFirstOrNull() ?: return
        val (name, version) = request
        val service = services[name]
        if (service == null || serviceVersions[name] != version) { resolveNext(); return }
        resolving = true
        val generation = discoveryGeneration
        val token = ++resolveToken
        resolveDeadline = coordinator.schedule({
            if (running.get() && token == resolveToken && resolving) {
                resolveToken++
                resolving = false
                restartDiscovery()
            }
        }, 10, TimeUnit.SECONDS)
        val callback = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = post {
                if (token != resolveToken) return@post
                resolveDeadline?.cancel(false)
                resolving = false
                if (generation == discoveryGeneration && serviceVersions[name] == version) {
                    coordinator.schedule({
                        if (running.get() && generation == discoveryGeneration && serviceVersions[name] == version) {
                            resolveQueue.add(name to version)
                            resolveNext()
                        }
                    }, 2, TimeUnit.SECONDS)
                }
                resolveNext()
            }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) = post {
                if (token != resolveToken) return@post
                resolveDeadline?.cancel(false)
                resolving = false
                if (generation == discoveryGeneration && serviceVersions[name] == version && services.containsKey(name)) {
                    val target = serviceInfo.attributes["target"]?.toString(StandardCharsets.UTF_8)
                    val id = serviceInfo.attributes["senderID"]?.toString(StandardCharsets.UTF_8)
                    val host = serviceInfo.host
                    if ((target.isNullOrBlank() || target == receiverID) && !id.isNullOrBlank() && host != null) {
                        serviceIDs[name] = id
                        macs[id] = DiscoveredMac(serviceInfo, id, name,
                            InetSocketAddress(host, serviceInfo.port), SystemClock.elapsedRealtime())
                        publishMacs()
                        if (policy.selectedMac == id && policy.wantsConnection && activeToken == null) {
                            scheduleRetry(0)
                        }
                    }
                }
                resolveNext()
            }
        }
        try {
            nsdManager.resolveService(service, callback)
        } catch (error: Exception) {
            callback.onResolveFailed(service, -1)
        }
    }

    private fun advertiseReceiver() {
        val deviceName = Settings.Global.getString(
            appContext.contentResolver,
            "device_name",
        )?.trim()?.takeIf { it.isNotEmpty() }
            ?: listOf(Build.MANUFACTURER, Build.MODEL)
                .filter { it.isNotBlank() }
                .joinToString(" ")
                .ifBlank { "Fire TV" }

        val service = NsdServiceInfo().apply {
            serviceName = deviceName
            serviceType = RECEIVER_SERVICE_TYPE
            port = STREAM_PORT
            setAttribute("id", receiverID)
            setAttribute("kind", "firetv")
        }
        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "advertising receiver as ${serviceInfo.serviceName}")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "receiver advertisement failed: $errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
        }
        registrationListener = registration
        nsdManager.registerService(service, NsdManager.PROTOCOL_DNS_SD, registration)
    }

    private fun scheduleRetry(delay: Long = policy.retryDelayMilliseconds()) {
        if (!policy.wantsConnection || activeToken != null) return
        retry?.cancel(false)
        val generation = policy.generation
        retry = coordinator.schedule({
            if (running.get() && generation == policy.generation) attemptSelectedMac()
        }, delay + if (delay > 0) random.nextInt(500) else 0, TimeUnit.MILLISECONDS)
    }

    private fun attemptSelectedMac() {
        if (!running.get() || activeToken != null || !policy.wantsConnection) return
        val mac = macs[policy.selectedMac]
        if (mac == null || !isAvailable(mac)) {
            listener.onStatus("Waiting for the selected Mac…", false)
            scheduleRetry()
            return
        }
        // Refresh DNS-SD in parallel so a stale DHCP endpoint isn't retried forever.
        val name = mac.service.serviceName
        if (!resolveQueue.any { it.first == name }) {
            resolveQueue.add(name to (serviceVersions[name] ?: 0))
            resolveNext()
        }
        val token = policy.beginAttempt() ?: return
        activeToken = token
        val socket = Socket()
        clientSocket = socket // assigned before connect so Stop can cancel it
        listener.onStatus("Connecting to ${mac.name}…", false)
        executor.execute {
            try {
                socket.tcpNoDelay = true
                socket.receiveBufferSize = 512 * 1024
                socket.connect(mac.endpoint, CONNECT_TIMEOUT_MS)
                if (!running.get() || clientSocket !== socket || socket.isClosed) return@execute
                post {
                    policy.transition(token, MacConnectionPolicy.State.CONNECTING,
                                      MacConnectionPolicy.State.AUTHENTICATING)
                }
                val requiresPairing = handleClient(socket, token, mac.id)
                post { finishSession(socket, token, requiresPairing) }
            } catch (error: Exception) {
                Log.w(TAG, "Mac connection failed", error)
                post { finishSession(socket, token, false) }
            } finally {
                runCatching { socket.close() }
                // Handles cancellation before entering the handshake.
                post { if (activeToken == token) finishSession(socket, token, false) }
            }
        }
    }

    private fun runSession(socket: Socket, token: Long, senderID: String?) {
        executor.execute {
            val pairingRequired = try { handleClient(socket, token, senderID) }
                catch (error: Exception) { false }
            runCatching { socket.close() }
            post { finishSession(socket, token, pairingRequired) }
        }
    }

    private fun finishSession(socket: Socket, token: Long, pairingRequired: Boolean) {
        if (activeToken != token) return
        runCatching { socket.close() }
        if (clientSocket === socket) clientSocket = null
        activeToken = null
        rotatePairingCode()
        heartbeat?.cancel(false)
        heartbeat = null
        mediaDeadline?.cancel(false)
        mediaDeadline = null
        if (pendingSelection != null) { startSelection(); return }
        if (policy.failed(token, pairingRequired)) {
            if (!pairingRequired) {
                listener.onStatus("Connection lost — reconnecting to the selected Mac…", false)
                scheduleRetry()
            }
        } else if (!policy.wantsConnection) {
            listener.onStatus("Choose a Mac and press Connect", false)
        }
    }

    private fun sendHeartbeat() {
        val output = activeOutput ?: return
        enqueueControl(output, JSONObject().put("type", "heartbeat"))
    }

    private fun enqueueControl(output: DataOutputStream, message: JSONObject): Boolean {
        if (!running.get() || !controlWritePending.compareAndSet(false, true)) return false
        val socket = clientSocket
        val deadline = try {
            coordinator.schedule({ runCatching { socket?.close() } }, 10, TimeUnit.SECONDS)
        } catch (error: Exception) { controlWritePending.set(false); return false }
        try {
            controlWriter.execute {
                try {
                    synchronized(outputLock) { writeControl(output, message) }
                } catch (error: Exception) {
                    runCatching { socket?.close() }
                } finally {
                    deadline.cancel(false)
                    controlWritePending.set(false)
                }
            }
        } catch (error: Exception) { deadline.cancel(false); controlWritePending.set(false); return false }
        return true
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

    private fun deriveRememberedSessionKey(
        secret: ByteArray,
        salt: ByteArray,
        serverChallenge: ByteArray,
        clientChallenge: ByteArray,
    ): ByteArray = hmac(
        secret,
        "session".toByteArray(StandardCharsets.UTF_8),
        salt,
        serverChallenge,
        clientChallenge,
    )

    private fun deriveTrustSecret(
        key: ByteArray,
        serverChallenge: ByteArray,
        clientChallenge: ByteArray,
    ): ByteArray = hmac(
        key,
        "remember-receiver".toByteArray(StandardCharsets.UTF_8),
        serverChallenge,
        clientChallenge,
    )

    private fun loadTrustedSender(senderID: String): ByteArray? =
        preferences.getString("$TRUSTED_SENDER_PREFIX$senderID", null)?.let(::decode)

    private fun saveTrustedSender(senderID: String, secret: ByteArray) {
        preferences.edit()
            .putString("$TRUSTED_SENDER_PREFIX$senderID", encode(secret))
            .apply()
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
        const val RECEIVER_SERVICE_TYPE = "_iosfiretv._tcp."
        const val PREFERENCES_NAME = "remembered_devices"
        const val RECEIVER_ID_KEY = "receiver_id"
        const val TRUSTED_SENDER_PREFIX = "trusted_sender."
        const val PACKET_JSON = 0
        const val STREAM_PORT = 49_218
        const val CONNECT_TIMEOUT_MS = 5_000
        const val PACKET_ENCRYPTED_MEDIA = 2
        const val MEDIA_VERSION = 2
        const val MEDIA_HEADER_BYTES = 11
        const val MEDIA_VIDEO_CONFIGURATION = 1
        const val MEDIA_VIDEO_FRAME = 2
        const val MEDIA_AUDIO_CONFIGURATION = 3
        const val MEDIA_AUDIO_FRAME = 4
        const val MEDIA_CAPTION = 5
        const val MEDIA_HEARTBEAT = 6
        const val MEDIA_REMOTE_SEEK_RESULT = 7
        const val FEATURE_HEARTBEAT = "connection-heartbeat-v1"
        const val FEATURE_LIVE_CAPTIONS = "live-captions-v1"
        const val AUDIO_PCM_16 = 1
        const val AUDIO_AAC_LC = 2
        const val GCM_NONCE_BYTES = 12
        const val PBKDF2_ITERATIONS = 120_000
        const val MAX_JSON_PACKET_BYTES = 64 * 1024
        const val MAX_FRAME_PACKET_BYTES = 8 * 1024 * 1024
        const val FEATURE_CINEMA_BUFFER = "cinema-buffer-v1"
        const val FEATURE_RECEIVER_REPORTS = "receiver-report-v1"
        const val FEATURE_KEYFRAME_REQUEST = "keyframe-request-v1"
        const val FEATURE_AAC_LC = "aac-lc-v1"
        const val FEATURE_REMOTE_MEDIA_CONTROLS = "remote-media-controls-v1"
        const val REMOTE_COMMAND_TOGGLE_PLAY_PAUSE = "toggle_play_pause"
        val SUPPORTED_FEATURES = setOf(
            ReceiverControlAuthentication.FEATURE,
            FEATURE_HEARTBEAT,
            RemoteMediaCommand.SEEK_FEATURE,
            FEATURE_CINEMA_BUFFER,
            FEATURE_LIVE_CAPTIONS,
            FEATURE_RECEIVER_REPORTS,
            FEATURE_KEYFRAME_REQUEST,
            FEATURE_REMOTE_MEDIA_CONTROLS,
        )
    }
}

data class CinemaPlaybackReport(
    val videoBufferMilliseconds: Long,
    val audioBufferMilliseconds: Long,
    val decoderBacklogMilliseconds: Long,
    val underruns: Long,
    val recoveries: Long,
    val lastPresentedTimestampMilliseconds: Long,
    val targetBufferMilliseconds: Long = 180L,
)
