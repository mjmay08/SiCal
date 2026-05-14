package dev.mmay.sical

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader

class MainActivity : FlutterActivity() {
	private val channelName = "dev.mmay.sical/calendar_file"
	private var channel: MethodChannel? = null
	private val pendingCalendarTexts = mutableListOf<String>()

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).also {
			it.setMethodCallHandler { call, result ->
				when (call.method) {
					"consumePendingCalendarFileText" -> {
						if (pendingCalendarTexts.isEmpty()) {
							result.success(null)
						} else {
							result.success(pendingCalendarTexts.removeAt(0))
						}
					}

					else -> result.notImplemented()
				}
			}
		}

		enqueueCalendarTextFromIntent(intent)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		enqueueCalendarTextFromIntent(intent)
	}

	private fun enqueueCalendarTextFromIntent(intent: Intent?) {
		if (intent == null) return
		val action = intent.action ?: return
		if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return

		val candidateUri = when (action) {
			Intent.ACTION_VIEW -> intent.data
			Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM)
			else -> null
		}

		val calendarText = readCalendarText(candidateUri)
		if (calendarText.isNullOrBlank()) return

		pendingCalendarTexts.add(calendarText)
		channel?.invokeMethod("onCalendarFileText", null)
	}

	private fun readCalendarText(uri: Uri?): String? {
		if (uri == null) return null

		val text = try {
			contentResolver.openInputStream(uri)?.use { inputStream ->
				InputStreamReader(inputStream).use { inputStreamReader ->
					BufferedReader(inputStreamReader).readText()
				}
			}
		} catch (_: Exception) {
			null
		}

		if (text.isNullOrBlank()) return null
		if (looksLikeICalendar(uri, text)) return text
		return null
	}

	private fun looksLikeICalendar(uri: Uri, text: String): Boolean {
		val mime = contentResolver.getType(uri)?.lowercase()
		if (mime == "text/calendar") return true

		val uriText = uri.toString().lowercase()
		if (uriText.endsWith(".ics") ||
			uriText.endsWith(".ical") ||
			uriText.endsWith(".ifb") ||
			uriText.endsWith(".vcs")) {
			return true
		}

		val displayName = resolveDisplayName(uri)?.lowercase()
		if (displayName != null &&
			(displayName.endsWith(".ics") ||
				displayName.endsWith(".ical") ||
				displayName.endsWith(".ifb") ||
				displayName.endsWith(".vcs"))) {
			return true
		}

		return text.contains("BEGIN:VCALENDAR", ignoreCase = true)
	}

	private fun resolveDisplayName(uri: Uri): String? {
		return try {
			contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
				?.use { cursor ->
					if (!cursor.moveToFirst()) return@use null
					val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
					if (idx >= 0) cursor.getString(idx) else null
				}
		} catch (_: Exception) {
			null
		}
	}
}
