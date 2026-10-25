package com.example.pulsepath

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

class NetworkStatusBridge(context: Context) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var registered = false
    private var last: Boolean? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = publish()
        override fun onLost(network: Network) = publish()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = publish()
    }
    fun attach(messenger: BinaryMessenger) {
        EventChannel(messenger, "pulsepath/network_status").setStreamHandler(this)
    }
    private fun publish() {
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
        val online = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        handler.post {
            if (last != online) { last = online; sink?.success(online) }
        }
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events; last = null
        if (!registered) {
            try { manager.registerDefaultNetworkCallback(callback); registered = true }
            catch (_: RuntimeException) { /* Dart keeps a foreground retry timer. */ }
        }
        publish()
    }
    override fun onCancel(arguments: Any?) = close()
    fun close() {
        if (registered) {
            try { manager.unregisterNetworkCallback(callback) } catch (_: RuntimeException) {}
        }
        registered = false; sink = null; last = null
    }
}
