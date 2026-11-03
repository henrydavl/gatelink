package com.example.gatelink.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkTest {
    @Test fun validatesHosts() {
        listOf("vpn.bri.co.id", "203.0.113.10", "a").forEach { assertTrue(it, Network.isValidHost(it)) }
        listOf("", "-oProxy=x", "vpn.example.com/x", "vpn example.com", "a".repeat(254)).forEach { assertFalse(it, Network.isValidHost(it)) }
    }

    @Test fun parsesRoutes() {
        assertEquals("10.0.0.0" to 8, Network.route("10.0.0.0/8"))
        assertEquals("10.1.0.0" to 16, Network.route("10.1.0.0/255.255.0.0"))
        assertEquals("192.0.2.7" to 32, Network.route("192.0.2.7"))
        assertEquals("fd00::" to 64, Network.route("fd00::/64"))
        assertNull(Network.route("10.0.0.0/33"))
        assertNull(Network.route("/8"))
        assertEquals(24, Network.prefixLength("255.255.255.0"))
        assertEquals(32, Network.prefixLength(null))
    }

    @Test fun matchesCertificateNames() {
        assertTrue(Network.nameMatches("vpn.bri.co.id", "VPN.bri.co.id"))
        assertTrue(Network.nameMatches("*.bri.co.id", "vpn.bri.co.id"))
        assertFalse(Network.nameMatches("*.bri.co.id", "a.vpn.bri.co.id"))
        assertFalse(Network.nameMatches("*.bri.co.id", "bri.co.id"))
        // On NAT64 networks openconnect's own hostname becomes this; never accept it for the cert.
        assertFalse(Network.nameMatches("vpn.bri.co.id", "64:ff9b::673f:60be"))
    }
}
