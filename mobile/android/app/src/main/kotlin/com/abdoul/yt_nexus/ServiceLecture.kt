package com.abdoul.yt_nexus

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.net.URL
import kotlin.concurrent.thread

/**
 * Lecture en arrière-plan : session média + notification avec contrôles
 * (précédent, lecture/pause, suivant, fermer), visible sur l'écran verrouillé.
 * Le lecteur reste côté Flutter (video_player) : ici on affiche l'état reçu et on
 * renvoie les commandes de l'utilisateur à Dart.
 */
class ServiceLecture : Service() {
    private var session: MediaSessionCompat? = null
    private var verrou: PowerManager.WakeLock? = null
    private var pochette: Bitmap? = null
    private var urlPochette: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        session = MediaSessionCompat(this, "YT-NEXUS").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = envoyer("play")
                override fun onPause() = envoyer("pause")
                override fun onSkipToNext() = envoyer("next")
                override fun onSkipToPrevious() = envoyer("prev")
                override fun onStop() = envoyer("stop")
                override fun onSeekTo(pos: Long) = envoyer("seek", pos)
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_ARRETER) {
            arreter()
            return START_NOT_STICKY
        }
        if (action != null && action != ACTION_ETAT) {
            // Bouton de la notification
            envoyer(action)
            if (dernier == null) stopSelf()
            return START_NOT_STICKY
        }
        if (intent == null) {
            arreter()
            return START_NOT_STICKY
        }
        appliquer(
            Etat(
                intent.getStringExtra("titre") ?: "", intent.getStringExtra("artiste") ?: "",
                intent.getStringExtra("image"), intent.getBooleanExtra("lecture", false),
                intent.getLongExtra("position", 0), intent.getLongExtra("duree", 0),
                intent.getFloatExtra("vitesse", 1f), intent.getBooleanExtra("prec", false),
                intent.getBooleanExtra("suiv", false),
            )
        )
        return START_NOT_STICKY
    }

    private fun envoyer(commande: String, position: Long = 0) {
        ecouteur?.invoke(mapOf("type" to "media", "action" to commande, "position" to position))
    }

    private data class Etat(
        val titre: String, val artiste: String, val image: String?, val lecture: Boolean,
        val position: Long, val duree: Long, val vitesse: Float, val prec: Boolean, val suiv: Boolean,
    )

    private var dernier: Etat? = null

    private fun appliquer(e: Etat) {
        dernier = e
        val s = session ?: return
        val meta = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, e.titre)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, e.artiste)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, e.duree)
        pochette?.let { meta.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it) }
        s.setMetadata(meta.build())
        var actions = PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_SEEK_TO or
            PlaybackStateCompat.ACTION_STOP
        if (e.prec) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        if (e.suiv) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (e.lecture) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    e.position, if (e.lecture) e.vitesse else 0f,
                )
                .build()
        )
        // La pochette se charge en arrière-plan puis la notification est rafraîchie
        if (e.image != null && e.image != urlPochette) {
            urlPochette = e.image
            pochette = null
            thread {
                val b = try {
                    URL(e.image).openStream().use { BitmapFactory.decodeStream(it) }
                } catch (x: Exception) {
                    null
                }
                if (b != null && urlPochette == e.image) {
                    pochette = b
                    dernier?.let { instance?.appliquer(it) }
                }
            }
        }
        canal(this)
        val n = notification(e)
        ServiceCompat.startForeground(
            this, ID, n,
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0,
        )
        // Écran éteint : le processeur doit rester éveillé pendant la lecture
        if (e.lecture) {
            if (verrou == null) {
                verrou = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "yt-nexus:lecture")
            }
            if (verrou?.isHeld == false) verrou?.acquire(4 * 60 * 60 * 1000L)
        } else {
            verrou?.let { if (it.isHeld) it.release() }
        }
    }

    private fun bouton(action: String, code: Int): PendingIntent = PendingIntent.getService(
        this, code, Intent(this, ServiceLecture::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun notification(e: Etat): android.app.Notification {
        val b = NotificationCompat.Builder(this, CANAL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(e.titre)
            .setContentText(e.artiste)
            .setLargeIcon(pochette)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(e.lecture)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 0,
                    Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            )
            .setDeleteIntent(bouton("stop", 5))
        var n = 0
        val visibles = mutableListOf<Int>()
        if (e.prec) {
            b.addAction(android.R.drawable.ic_media_previous, "Précédent", bouton("prev", 1)); visibles += n++
        }
        if (e.lecture) {
            b.addAction(android.R.drawable.ic_media_pause, "Pause", bouton("pause", 2))
        } else {
            b.addAction(android.R.drawable.ic_media_play, "Lecture", bouton("play", 2))
        }
        visibles += n++
        if (e.suiv) {
            b.addAction(android.R.drawable.ic_media_next, "Suivant", bouton("next", 3)); visibles += n++
        }
        b.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Fermer", bouton("stop", 4))
        b.setStyle(
            androidx.media.app.NotificationCompat.MediaStyle()
                .setMediaSession(session?.sessionToken)
                .setShowActionsInCompactView(*visibles.toIntArray())
        )
        return b.build()
    }

    private fun arreter() {
        verrou?.let { if (it.isHeld) it.release() }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        verrou?.let { if (it.isHeld) it.release() }
        verrou = null
        session?.isActive = false
        session?.release()
        session = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val CANAL = "lecture"
        private const val ID = 2
        private const val ACTION_ETAT = "etat"
        private const val ACTION_ARRETER = "arreter"

        @Volatile private var instance: ServiceLecture? = null
        var ecouteur: ((Map<String, Any?>) -> Unit)? = null

        private fun canal(ctx: Context) {
            ctx.getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CANAL, "Lecture", NotificationManager.IMPORTANCE_LOW)
            )
        }

        private fun etat(d: Map<String, Any?>) = Etat(
            d["titre"] as? String ?: "", d["artiste"] as? String ?: "", d["image"] as? String,
            d["lecture"] == true, (d["position"] as? Number)?.toLong() ?: 0L,
            (d["duree"] as? Number)?.toLong() ?: 0L, (d["vitesse"] as? Number)?.toFloat() ?: 1f,
            d["prec"] == true, d["suiv"] == true,
        )

        /** Appelé sur le thread principal. Service déjà lancé : on met à jour directement
         *  (démarrer un service au premier plan depuis l'arrière-plan est refusé par Android). */
        fun mettreAJour(ctx: Context, d: Map<String, Any?>) {
            instance?.let {
                it.appliquer(etat(d))
                return
            }
            val i = Intent(ctx, ServiceLecture::class.java).setAction(ACTION_ETAT)
                .putExtra("titre", d["titre"] as? String ?: "")
                .putExtra("artiste", d["artiste"] as? String ?: "")
                .putExtra("image", d["image"] as? String)
                .putExtra("lecture", d["lecture"] == true)
                .putExtra("position", (d["position"] as? Number)?.toLong() ?: 0L)
                .putExtra("duree", (d["duree"] as? Number)?.toLong() ?: 0L)
                .putExtra("vitesse", (d["vitesse"] as? Number)?.toFloat() ?: 1f)
                .putExtra("prec", d["prec"] == true)
                .putExtra("suiv", d["suiv"] == true)
            try {
                ctx.startForegroundService(i)
            } catch (e: Exception) {
                // Android refuse parfois un démarrage depuis l'arrière-plan : la lecture continue sans notification
            }
        }

        fun arreter(ctx: Context) {
            if (instance == null) return
            try {
                ctx.startService(Intent(ctx, ServiceLecture::class.java).setAction(ACTION_ARRETER))
            } catch (e: Exception) {
                instance?.arreter()
            }
        }
    }
}
