package com.example.gatelink.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.gatelink.MainViewModel
import com.example.gatelink.R
import com.example.gatelink.otp.Totp
import com.example.gatelink.vault.Account
import com.example.gatelink.vpn.VpnState
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.delay

private val Green = Color(0xFF34C759)
private val Orange = Color(0xFFFF9500)
private val Red = Color(0xFFFF3B30)

/** The Android version of the menu bar popover: account and code, connection
 *  form, and the Connect / Cancel / Disconnect button. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GateLinkScreen(model: MainViewModel) {
    val state by model.vpnState.collectAsState()
    val accounts by model.vault.accounts.collectAsState()
    var addingAccount by remember { mutableStateOf(false) }
    var settingPassword by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    val account = model.account
    val connected = state is VpnState.Connected
    val busy = state is VpnState.Authenticating || state is VpnState.Connecting || state is VpnState.Disconnecting

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("GateLink", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    if (account != null) {
                        Box {
                            IconButton(onClick = { menuOpen = true }) { Icon(painterResource(R.drawable.ic_more), "More") }
                            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                DropdownMenuItem(text = { Text("Delete Account…", color = Red) }, onClick = { menuOpen = false; confirmDelete = true })
                            }
                        }
                    }
                },
                actions = { IconButton(onClick = { addingAccount = true }) { Icon(painterResource(R.drawable.ic_add), "Add Account") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Card(Modifier.fillMaxWidth()) {
                if (account != null) {
                    AccountRow(model, account, accounts)
                } else {
                    Column(Modifier.fillMaxWidth().padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("No 2FA account yet", style = MaterialTheme.typography.titleMedium)
                        Text("Add the QR code or secret key your VPN gave you.", color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                        TextButton(onClick = { addingAccount = true }) { Text("Add Account…") }
                    }
                }
            }

            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatusLine(state, model.gateway)
                    if (!connected) {
                        HorizontalDivider()
                        OutlinedTextField(
                            value = model.gateway, onValueChange = { model.gateway = it }, label = { Text("Portal") },
                            placeholder = { Text("vpn.example.com") }, singleLine = true, enabled = !busy,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth(),
                        )
                        OutlinedTextField(
                            value = model.username, onValueChange = model::updateUsername, label = { Text("Username") },
                            placeholder = { Text("VPN username") }, singleLine = true, enabled = !busy,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii), modifier = Modifier.fillMaxWidth(),
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Password", Modifier.weight(1f))
                            val saved = account?.hasPassword == true
                            Text(if (saved) "Saved on this phone" else "Not set", color = if (saved) MaterialTheme.colorScheme.onSurfaceVariant else Orange)
                            TextButton(onClick = { settingPassword = true }, enabled = account != null && !busy) { Text(if (saved) "Change…" else "Set…") }
                        }
                    }
                }
            }

            PrimaryButton(state, onClick = { model.primaryAction() })
            Feedback(model.message, state)

            Text("GateLink ${model.version}", Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
        }
    }

    if (addingAccount) AddAccountSheet(model, onDismiss = { addingAccount = false })
    if (settingPassword) PasswordSheet(model, onDismiss = { settingPassword = false })
    if (confirmDelete && account != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${account.issuer}?") },
            text = { Text("The 2FA secret and saved password are removed from this phone.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; model.deleteCurrentAccount() }) { Text("Delete", color = Red) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

/** Issuer and username, the account switcher, and the code with copy and reveal. */
@Composable
private fun AccountRow(model: MainViewModel, account: Account, accounts: List<Account>) {
    var switching by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(account.issuer, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                if (accounts.size > 1) {
                    Box {
                        IconButton(onClick = { switching = true }, enabled = model.canSwitchAccount, modifier = Modifier.size(32.dp)) {
                            Icon(painterResource(R.drawable.ic_unfold), "Switch Account", Modifier.size(18.dp))
                        }
                        DropdownMenu(expanded = switching, onDismissRequest = { switching = false }) {
                            accounts.forEach { other ->
                                DropdownMenuItem(
                                    text = { Text(other.issuer + if (other.username.isEmpty()) "" else " (${other.username})") },
                                    onClick = { switching = false; model.select(other) },
                                )
                            }
                        }
                    }
                }
            }
            Text(account.username.ifEmpty { account.label }, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Box(Modifier.clickable(onClickLabel = "Copy code") { model.copyCode() }) { CodeView(model.revealed) }
        IconButton(onClick = { model.copyCode() }) { Icon(painterResource(R.drawable.ic_copy), "Copy code", tint = MaterialTheme.colorScheme.primary) }
        IconButton(onClick = { model.toggleReveal() }) {
            val hidden = model.revealed == null
            Icon(painterResource(if (hidden) R.drawable.ic_visibility else R.drawable.ic_visibility_off),
                if (hidden) "Show code" else "Hide code", tint = MaterialTheme.colorScheme.primary)
        }
    }
}

/** The current code with a countdown ring, or a masked placeholder. */
@Composable
private fun CodeView(totp: Totp?) {
    var now by remember { mutableLongStateOf(Totp.nowSeconds()) }
    LaunchedEffect(totp) {
        while (totp != null) {
            now = Totp.nowSeconds()
            delay(1_000)
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (totp != null) {
            val code = totp.code(now)
            Text(if (code.length == 6) code.take(3) + " " + code.takeLast(3) else code,
                fontFamily = FontFamily.Monospace, fontSize = 20.sp)
            val remaining = totp.secondsRemaining(now)
            Box(contentAlignment = Alignment.Center, modifier = Modifier.semantics { contentDescription = "$remaining seconds left" }) {
                CircularProgressIndicator(
                    progress = { remaining / totp.period.toFloat() }, modifier = Modifier.size(24.dp), strokeWidth = 2.5.dp,
                    color = if (remaining <= 5) Orange else MaterialTheme.colorScheme.primary,
                    trackColor = MaterialTheme.colorScheme.surfaceVariant,
                )
                Text("$remaining", fontSize = 9.sp)
            }
        } else {
            Text("••• •••", fontFamily = FontFamily.Monospace, fontSize = 20.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.semantics { contentDescription = "Code hidden" })
        }
    }
}

@Composable
private fun StatusLine(state: VpnState, portal: String) {
    val (text, icon, color) = when (state) {
        is VpnState.Idle, is VpnState.Failed -> Triple("Not connected", if (state is VpnState.Failed) R.drawable.ic_error else R.drawable.ic_circle, MaterialTheme.colorScheme.onSurfaceVariant)
        is VpnState.Authenticating -> Triple("Logging in…", R.drawable.ic_sync, MaterialTheme.colorScheme.primary)
        is VpnState.Connecting -> Triple("Starting the tunnel…", R.drawable.ic_sync, MaterialTheme.colorScheme.primary)
        is VpnState.Disconnecting -> Triple("Disconnecting…", R.drawable.ic_sync, MaterialTheme.colorScheme.primary)
        is VpnState.Connected -> Triple(
            "Connected to ${state.host.ifEmpty { portal }} since ${DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(state.sinceMillis))}",
            R.drawable.ic_check_circle, Green,
        )
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(painterResource(icon), null, tint = color, modifier = Modifier.size(20.dp))
        Text(text, color = color, fontWeight = FontWeight.SemiBold)
    }
}

/** Disconnect is a gray button with a red label; a solid red one is too loud. */
@Composable
private fun PrimaryButton(state: VpnState, onClick: () -> Unit) {
    val modifier = Modifier.fillMaxWidth().height(52.dp)
    when (state) {
        is VpnState.Connected -> OutlinedButton(onClick, modifier) { Text("Disconnect", color = Red, fontSize = 17.sp) }
        is VpnState.Authenticating, is VpnState.Connecting ->
            Button(onClick, modifier, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant,
                contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) { Text("Cancel", fontSize = 17.sp) }
        is VpnState.Disconnecting -> Button({}, modifier, enabled = false) { Text("Disconnecting…", fontSize = 17.sp) }
        else -> Button(onClick, modifier) { Text("Connect", fontSize = 17.sp) }
    }
}

@Composable
private fun Feedback(message: String?, state: VpnState) {
    val failure = (state as? VpnState.Failed)?.reason
    val text = message ?: failure ?: return
    val isError = message == null || !(listOf("Added", "Deleted", "Code copied", "Password saved", "Waiting for the next code").any { message.startsWith(it) })
    if (isError) ErrorCallout(text) else Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
}

/** An error message in a soft red box, calmer than red text. */
@Composable
fun ErrorCallout(message: String) {
    Row(
        Modifier.fillMaxWidth().background(Red.copy(alpha = 0.12f), RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 10.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Error: $message" },
        verticalAlignment = Alignment.Top,
    ) {
        Icon(painterResource(R.drawable.ic_warning), null, tint = Red, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(message, style = MaterialTheme.typography.bodyMedium)
    }
}
