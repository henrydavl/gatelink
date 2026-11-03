package com.example.gatelink.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.example.gatelink.MainViewModel
import com.example.gatelink.R
import com.example.gatelink.otp.OtpAuthUri
import com.example.gatelink.vault.AccountDraft
import kotlinx.coroutines.launch

/** Adds a 2FA account from the camera, a QR image, a copied otpauth:// link, or the secret key. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddAccountSheet(model: MainViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var scanned by remember { mutableStateOf<AccountDraft?>(null) }
    var manualInput by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    fun use(read: () -> OtpAuthUri) {
        try {
            val draft = AccountDraft.fromUri(read())
            scanned = draft
            manualInput = ""
            if (username.isEmpty()) username = draft.account.username
            error = null
        } catch (e: Exception) {
            scanned = null
            error = e.message
        }
    }

    val pickImage = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) use { OtpAuthUri.parse(readQr(context, uri)) }
    }
    var scanning by remember { mutableStateOf(false) }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scanning = true else error = "GateLink needs the camera to scan. Allow it in Settings, or choose a QR image."
    }
    if (scanning) {
        QrScannerDialog(onResult = { text -> scanning = false; use { OtpAuthUri.parse(text) } }, onDismiss = { scanning = false })
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add 2FA Account", style = MaterialTheme.typography.titleLarge)

            Text("From a QR code", style = MaterialTheme.typography.labelLarge)
            scanned?.let {
                Text("Found ${it.account.issuer}${if (it.account.label.isEmpty()) "" else " (${it.account.label})"}", color = Color(0xFF34C759))
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                        scanning = true
                    } else {
                        cameraPermission.launch(Manifest.permission.CAMERA)
                    }
                }) { Text("Scan QR Code") }
                OutlinedButton(onClick = { pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Text("Choose QR Image…")
                }
                OutlinedButton(onClick = {
                    val text = context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()
                    if (text.isNullOrBlank()) error = "The clipboard has no otpauth:// link." else use { OtpAuthUri.parse(text) }
                }) { Text("Paste Link") }
            }

            Text("Or enter it manually", style = MaterialTheme.typography.labelLarge)
            OutlinedTextField(manualInput, { manualInput = it }, Modifier.fillMaxWidth(), singleLine = true,
                placeholder = { Text("otpauth://totp/… or JBSWY3DP…") }, label = { Text("otpauth:// URI or secret key") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii))
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text("Name (optional)") }, placeholder = { Text("e.g. Company VPN") })
            OutlinedTextField(username, { username = it }, Modifier.fillMaxWidth(), singleLine = true,
                label = { Text("VPN username") },
                supportingText = { Text("The login name for the gateway. Defaults to the name in the QR code.") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii))

            error?.let { ErrorCallout(it) }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Button(
                    enabled = !saving && (scanned != null || manualInput.isNotBlank()),
                    onClick = {
                        scope.launch {
                            saving = true
                            try {
                                val draft = if (manualInput.isNotBlank()) {
                                    AccountDraft.fromManualInput(manualInput, name, username)
                                } else {
                                    val base = scanned ?: return@launch
                                    base.copy(account = base.account.copy(
                                        username = username.trim().ifEmpty { base.account.username },
                                        issuer = name.trim().ifEmpty { base.account.issuer },
                                    ))
                                }
                                if (model.add(draft)) onDismiss() else error = "Unlock cancelled; the account was not saved."
                            } catch (e: Exception) {
                                error = e.message
                            } finally {
                                saving = false
                            }
                        }
                    },
                ) { Text("Add") }
            }
        }
    }
}

/** Sets the VPN password for the selected account. Password managers can fill it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PasswordSheet(model: MainViewModel, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var shows by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    // Never keep a typed password around.
    DisposableEffect(Unit) { onDispose { password = "" } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier.padding(horizontal = 20.dp).padding(bottom = 16.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("VPN Password", style = MaterialTheme.typography.titleLarge)
            model.account?.let {
                Text("For ${it.issuer} (${it.username}). It is saved on this phone; GateLink adds the current code when it logs in.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            OutlinedTextField(
                password, { password = it }, Modifier.fillMaxWidth().semantics { contentType = ContentType.Password },
                singleLine = true, label = { Text("VPN password") },
                visualTransformation = if (shows) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    IconButton(onClick = { shows = !shows }) {
                        Icon(painterResource(if (shows) R.drawable.ic_visibility_off else R.drawable.ic_visibility),
                            if (shows) "Hide password" else "Show password", Modifier.size(22.dp))
                    }
                },
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(Modifier.size(4.dp))
                Button(enabled = password.isNotEmpty() && !saving && model.account != null, onClick = {
                    scope.launch {
                        saving = true
                        if (model.savePassword(password)) onDismiss()
                        saving = false
                    }
                }) { Text("Save") }
            }
        }
    }
}
