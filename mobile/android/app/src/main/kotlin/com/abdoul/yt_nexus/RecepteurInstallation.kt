package com.abdoul.yt_nexus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller

/**
 * Résultat d'une installation lancée par PackageInstaller (mise à jour de l'app).
 * Si Android demande une confirmation, on ouvre sa fenêtre ; sinon (Android 12+, mises à jour
 * suivantes) l'installation se fait sans rien demander.
 */
class RecepteurInstallation : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val statut = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (statut) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                confirmation?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    ctx.startActivity(confirmation)
                } catch (e: Exception) {
                    ecouteur?.invoke(mapOf("type" to "install", "ok" to false, "message" to "Impossible d'ouvrir l'installateur"))
                }
            }
            PackageInstaller.STATUS_SUCCESS -> Unit // l'app est remplacée et redémarre
            else -> {
                val message = when (statut) {
                    PackageInstaller.STATUS_FAILURE_ABORTED -> "Installation annulée"
                    PackageInstaller.STATUS_FAILURE_CONFLICT, PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
                        "Signature différente de l'app installée : désinstalle puis réinstalle YT-NEXUS une fois"
                    PackageInstaller.STATUS_FAILURE_STORAGE -> "Pas assez d'espace de stockage"
                    else -> intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Installation impossible"
                }
                ecouteur?.invoke(mapOf("type" to "install", "ok" to false, "message" to message))
            }
        }
    }

    companion object {
        var ecouteur: ((Map<String, Any?>) -> Unit)? = null
    }
}

/** Après une mise à jour silencieuse l'app est arrêtée : une notification permet de la rouvrir. */
class RecepteurMiseAJour : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            ServiceTelechargement.notifierFin(ctx, "YT-NEXUS est à jour", "Touche pour rouvrir l'application")
        }
    }
}
