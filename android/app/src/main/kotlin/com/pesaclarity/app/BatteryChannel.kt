package com.pesaclarity.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Tells Dart whether the phone's battery saver may put the app to sleep, so Home can say new
 * messages may be missed, and opens the settings page where the person changes it.
 *
 * Only Android's own battery optimisation can be read. Samsung's "Sleeping apps" and "Deep
 * sleeping apps" lists (Settings › Battery › Background usage limits) have no public API, so an
 * app on them can still read as not restricted here; the sheet's steps cover those lists.
 *
 * The app never asks for REQUEST_IGNORE_BATTERY_OPTIMIZATIONS (Google Play restricts it to a few
 * kinds of app); it only opens Settings and lets the person choose.
 */
class BatteryChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.pesaclarity.app/battery")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> result.success(isIgnoring())
                "manufacturer" -> result.success(Build.MANUFACTURER.orEmpty())
                "openSettings" -> result.success(openSettings())
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun isIgnoring(): Boolean {
        val power = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return power.isIgnoringBatteryOptimizations(activity.packageName)
    }

    /**
     * This app's page in Settings, where Battery › Unrestricted is; failing that, the list of
     * battery optimisations. False when neither opens.
     */
    private fun openSettings(): Boolean {
        val appPage =
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", activity.packageName, null))
        val optimisations = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        for (intent in listOf(appPage, optimisations)) {
            try {
                activity.startActivity(intent)
                return true
            } catch (e: ActivityNotFoundException) {
                // Some phones leave out a settings page; try the next one.
            } catch (e: SecurityException) {
                // A locked-down work profile may refuse it.
            }
        }
        return false
    }
}
