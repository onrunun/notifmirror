package com.notifmirror.android.service

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log

/**
 * Browses for `_andnotif._tcp` services on the LAN. Returns resolved
 * (host, port) pairs via [callback]. The first call is the priority result;
 * the caller can ignore any subsequent ones.
 */
class Discovery(private val context: Context) {
    private val nsd by lazy { context.getSystemService(Context.NSD_SERVICE) as NsdManager }
    private val wifi by lazy { context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager }
    private var multicastLock: WifiManager.MulticastLock? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null

    fun start(onResolved: (host: String, port: Int) -> Unit) {
        stop()
        multicastLock = wifi.createMulticastLock("notifmirror-mdns").apply {
            setReferenceCounted(false)
            try { acquire() } catch (e: Throwable) { Log.w(TAG, "multicastLock", e) }
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "start discovery failed: $errorCode")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "stop discovery failed: $errorCode")
            }
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "discovery started")
            }
            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "discovery stopped")
            }
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "found ${serviceInfo.serviceName}")
                resolve(serviceInfo, onResolved)
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.i(TAG, "lost ${serviceInfo.serviceName}")
            }
        }
        discoveryListener = listener
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stop() {
        discoveryListener?.let {
            try { nsd.stopServiceDiscovery(it) } catch (e: Throwable) { /* ignore */ }
        }
        discoveryListener = null
        multicastLock?.let { runCatching { it.release() } }
        multicastLock = null
    }

    private fun resolve(info: NsdServiceInfo, onResolved: (String, Int) -> Unit) {
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "resolve failed: $errorCode")
            }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                val host = serviceInfo.host?.hostAddress ?: return
                val port = serviceInfo.port
                Log.i(TAG, "resolved -> $host:$port")
                onResolved(host, port)
            }
        })
    }

    companion object {
        const val SERVICE_TYPE = "_andnotif._tcp."
        private const val TAG = "Discovery"
    }
}
