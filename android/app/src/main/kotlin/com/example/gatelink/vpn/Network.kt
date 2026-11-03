package com.example.gatelink.vpn

/** Pure helpers for the gateway's network settings and certificate names. */
object Network {
    private val hostPattern = Regex("[A-Za-z0-9](?:[A-Za-z0-9.\\-]{0,251}[A-Za-z0-9])?")

    /** A DNS name or IPv4 literal; never an option or a path (same rule as macOS and iOS). */
    fun isValidHost(host: String) = host.length <= 253 && !host.startsWith("-") && hostPattern.matches(host)

    /** "255.255.0.0" → 16. */
    fun prefixLength(netmask: String?): Int {
        val parts = netmask?.split('.')?.mapNotNull { it.toIntOrNull() } ?: return 32
        if (parts.size != 4) return 32
        return parts.sumOf { Integer.bitCount(it and 0xFF) }
    }

    /** "10.0.0.0/8", "10.0.0.0/255.0.0.0" or "fd00::/64" → (address, prefix length). */
    fun route(route: String): Pair<String, Int>? {
        val parts = route.trim().split('/', limit = 2)
        val address = parts[0].takeIf { it.isNotEmpty() } ?: return null
        val ipv6 = address.contains(':')
        val prefix = when {
            parts.size == 1 -> if (ipv6) 128 else 32
            parts[1].contains('.') -> prefixLength(parts[1])
            else -> parts[1].toIntOrNull() ?: return null
        }
        return if (prefix in 0..(if (ipv6) 128 else 32)) address to prefix else null
    }

    /** True when a certificate DNS name (possibly "*.example.com") covers `host`. */
    fun nameMatches(pattern: String, host: String): Boolean {
        val name = pattern.lowercase().trimEnd('.')
        val target = host.lowercase().trimEnd('.')
        if (!name.startsWith("*.")) return name == target
        val suffix = name.substring(1)
        return target.endsWith(suffix) && !target.removeSuffix(suffix).contains('.') && target.length > suffix.length
    }
}
