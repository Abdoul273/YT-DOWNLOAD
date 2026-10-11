package com.abdoul.yt_nexus

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** Garde l'app en vie pendant les téléchargements (notification de progression). */
class ServiceTelechargement : Service() {
    private var verrou: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "pause_tout") {
            ecouteur?.invoke(mapOf("type" to "actionTelechargement", "action" to "pause_tout"))
            if (!actif) stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.getBooleanExtra("actif", false) != true) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            actif = false
            stopSelf()
            return START_NOT_STICKY
        }
        val n = construire(
            this, intent.getStringExtra("titre") ?: "", intent.getStringExtra("texte") ?: "",
            intent.getIntExtra("progression", -1),
            intent.getStringArrayListExtra("lignes") ?: emptyList(),
        )
        ServiceCompat.startForeground(
            this, ID_PROGRESSION, n,
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        if (verrou == null) {
            verrou = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "yt-nexus:telechargement")
                .apply { acquire(6 * 60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        verrou?.let { if (it.isHeld) it.release() }
        verrou = null
        actif = false
        super.onDestroy()
    }

    companion object {
        private const val CANAL_PROGRESSION = "progression"
        private const val CANAL_FIN = "termines"
        private const val ID_PROGRESSION = 1
        var ecouteur: ((Map<String, Any?>) -> Unit)? = null
        private var actif = false
        private var compteur = 100

        private fun canaux(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(CANAL_PROGRESSION, "Téléchargements en cours", NotificationManager.IMPORTANCE_LOW)
            )
            nm.createNotificationChannel(
                NotificationChannel(CANAL_FIN, "Téléchargements terminés", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }

        private fun ouvrirApp(ctx: Context): PendingIntent = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java)
                .putExtra("ouvrirTelechargements", true)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        private fun pause(ctx: Context): PendingIntent = PendingIntent.getService(
            ctx, 1, Intent(ctx, ServiceTelechargement::class.java).setAction("pause_tout"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        private fun construire(ctx: Context, titre: String, texte: String, progression: Int, lignes: List<String>): android.app.Notification {
            val style: NotificationCompat.Style = if (lignes.size > 1) {
                val inbox = NotificationCompat.InboxStyle()
                inbox.setBigContentTitle("Téléchargements YT-NEXUS")
                lignes.forEach { inbox.addLine(it) }
                inbox.setSummaryText(texte)
                inbox
            } else NotificationCompat.BigTextStyle().bigText(texte)
            return NotificationCompat.Builder(ctx, CANAL_PROGRESSION)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(titre)
                .setContentText(texte)
                .setStyle(style)
                .setSubText("YT-NEXUS · Téléchargement")
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setColor(0xFF818CF8.toInt())
                .setShowWhen(false)
                .addAction(android.R.drawable.ic_media_pause, "Tout mettre en pause", pause(ctx))
                .addAction(android.R.drawable.ic_menu_view, "Voir les téléchargements", ouvrirApp(ctx))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setContentIntent(ouvrirApp(ctx))
                .setProgress(100, progression.coerceIn(0, 100), progression < 0)
                .build()
        }

        fun mettreAJour(ctx: Context, enMarche: Boolean, titre: String, texte: String, progression: Int, lignes: List<String>) {
            canaux(ctx)
            try {
                if (enMarche) {
                    if (!actif) {
                        val i = Intent(ctx, ServiceTelechargement::class.java)
                            .putExtra("actif", true).putExtra("titre", titre)
                            .putExtra("texte", texte).putExtra("progression", progression)
                            .putStringArrayListExtra("lignes", ArrayList(lignes))
                        ctx.startForegroundService(i)
                        actif = true
                    } else {
                        ctx.getSystemService(NotificationManager::class.java)
                            .notify(ID_PROGRESSION, construire(ctx, titre, texte, progression, lignes))
                    }
                } else if (actif) {
                    actif = false
                    ctx.startService(Intent(ctx, ServiceTelechargement::class.java).putExtra("actif", false))
                }
            } catch (e: Exception) {
                // Android refuse parfois de démarrer un service depuis l'arrière-plan : on réessaiera
                // à la prochaine mise à jour.
                actif = false
            }
        }

        fun notifierFin(ctx: Context, titre: String, texte: String) {
            canaux(ctx)
            val n = NotificationCompat.Builder(ctx, CANAL_FIN)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(titre)
                .setContentText(texte)
                .setStyle(NotificationCompat.BigTextStyle().bigText(texte))
                .setSubText("YT-NEXUS · Prêt à lire")
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setColor(0xFF34D399.toInt())
                .setAutoCancel(true)
                .setContentIntent(ouvrirApp(ctx))
                .build()
            try {
                ctx.getSystemService(NotificationManager::class.java).notify(compteur++, n)
            } catch (e: SecurityException) {
                // notifications refusées
            }
        }
    }
}
