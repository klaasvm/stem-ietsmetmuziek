package com.example.music_tiles_stepper_edition

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val updateChannelName = "music_tiles_stepper_edition/update"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			updateChannelName,
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"canRequestPackageInstalls" -> {
					result.success(canRequestPackageInstalls())
				}

				"openUnknownSourcesSettings" -> {
					openUnknownSourcesSettings()
					result.success(true)
				}

				else -> result.notImplemented()
			}
		}
	}

	private fun canRequestPackageInstalls(): Boolean {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
			return true
		}
		return packageManager.canRequestPackageInstalls()
	}

	private fun openUnknownSourcesSettings() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
			return
		}

		val intent = Intent(
			Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
			Uri.parse("package:$packageName"),
		).apply {
			addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		}
		startActivity(intent)
	}
}
