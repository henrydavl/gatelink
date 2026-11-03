package com.example.gatelink.vault

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AccountLookupTest {
    private val jane = Account(id = "1", issuer = "Corp", label = "jane@corp", username = "jane")
    private val lab = Account(id = "2", issuer = "Lab", label = "jane@lab", username = "jane")
    private val bob = Account(id = "3", issuer = "Corp", label = "bob", username = "90184463")
    private val accounts = listOf(jane, lab, bob)

    @Test fun findsTheAccountForATypedUsername() {
        assertEquals(bob, Vault.accountForUsername(accounts, " 90184463 ", null))
        assertEquals(jane, Vault.accountForUsername(accounts, "JANE", null))
        assertEquals(lab, Vault.accountForUsername(accounts, "jane@lab", null))
        assertNull(Vault.accountForUsername(accounts, "nobody", null))
        assertNull(Vault.accountForUsername(accounts, "", null))
    }

    @Test fun keepsTheSelectedAccountWhenUsernamesAreShared() {
        assertEquals(lab, Vault.accountForUsername(accounts, "jane", preferring = "2"))
        assertEquals(jane, Vault.accountForUsername(accounts, "jane", preferring = "3"))
    }
}
