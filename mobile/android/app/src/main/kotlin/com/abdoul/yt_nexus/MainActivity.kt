package com.abdoul.yt_nexus

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Pont entre Flutter et yt-dlp embarqué (youtubedl-android : Python + yt-dlp + ffmpeg).
 * La logique (choix des pistes, file, relances) vit côté Dart ; ici on exécute
 * yt-dlp, on relaie ses lignes et on range les fichiers dans Téléchargements.
 */
class MainActivity : FlutterActivity() {
    private val pool = Executors.newCachedThreadPool()
    private val principal = Handler(Looper.getMainLooper())
    private var evenements: EventChannel.EventSink? = null
    private var partageEnAttente: String? = null
    @Volatile private var pret = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messager = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messager, "yt_nexus/natif").setMethodCallHandler { appel, res -> traiter(appel, res) }
        EventChannel(messager, "yt_nexus/evenements").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                evenements = sink
            }

            override fun onCancel(arguments: Any?) {
                evenements = null
            }
        })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        partageEnAttente = textePartage(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        textePartage(intent)?.let { emettre(mapOf("type" to "partage", "texte" to it)) }
    }

    private fun textePartage(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)
    }

    private fun emettre(e: Map<String, Any?>) {
        principal.post { evenements?.success(e) }
    }

    private fun repondre(res: MethodChannel.Result, valeur: Any?) = principal.post { res.success(valeur) }
    private fun echouer(res: MethodChannel.Result, msg: String?) = principal.post { res.error("erreur", msg, null) }

    private fun enFond(res: MethodChannel.Result, travail: () -> Any?) {
        pool.execute {
            // Throwable et pas Exception : une Error (ExceptionInInitializerError, UnsatisfiedLinkError…)
            // levée dans un thread du pool tuerait toute l'app au lieu d'être renvoyée à Flutter.
            try {
                repondre(res, travail())
            } catch (e: Throwable) {
                echouer(res, e.message ?: e.toString())
            }
        }
    }

    private fun traiter(appel: MethodCall, res: MethodChannel.Result) {
        when (appel.method) {
            "init" -> enFond(res) { initialiser() }
            "partageInitial" -> {
                res.success(partageEnAttente)
                partageEnAttente = null
            }
            "executer" -> executer(appel, res)
            "arreter" -> res.success(YoutubeDL.getInstance().destroyProcessById(appel.argument<String>("id")!!))
            "majYtdlp" -> enFond(res) {
                val canal = if (appel.argument<Boolean>("nightly") == true) YoutubeDL.UpdateChannel.NIGHTLY
                else YoutubeDL.UpdateChannel.STABLE
                val statut = YoutubeDL.getInstance().updateYoutubeDL(applicationContext, canal)
                mapOf(
                    "statut" to (statut?.name ?: "INCONNU"),
                    "version" to YoutubeDL.getInstance().versionName(applicationContext),
                )
            }
            "publier" -> enFond(res) {
                publier(File(appel.argument<String>("dossier")!!), appel.argument<String>("sousDossier") ?: "")
            }
            "existe" -> enFond(res) { existe(Uri.parse(appel.argument<String>("uri")!!)) }
            "supprimerFichier" -> enFond(res) {
                contentResolver.delete(Uri.parse(appel.argument<String>("uri")!!), null, null) > 0
            }
            "ouvrir" -> {
                val i = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(Uri.parse(appel.argument<String>("uri")!!), appel.argument<String>("mime") ?: "*/*")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                lancer(Intent.createChooser(i, "Ouvrir avec"), res)
            }
            "partager" -> {
                val i = Intent(Intent.ACTION_SEND).apply {
                    type = appel.argument<String>("mime") ?: "*/*"
                    putExtra(Intent.EXTRA_STREAM, Uri.parse(appel.argument<String>("uri")!!))
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                lancer(Intent.createChooser(i, "Partager"), res)
            }
            "ouvrirLien" -> lancer(Intent(Intent.ACTION_VIEW, Uri.parse(appel.argument<String>("url")!!)), res)
            "service" -> {
                ServiceTelechargement.mettreAJour(
                    this,
                    appel.argument<Boolean>("actif") == true,
                    appel.argument<String>("titre") ?: "",
                    appel.argument<String>("texte") ?: "",
                    appel.argument<Int>("progression") ?: -1,
                )
                res.success(null)
            }
            "notifier" -> {
                ServiceTelechargement.notifierFin(
                    this, appel.argument<String>("titre") ?: "", appel.argument<String>("texte") ?: "",
                )
                res.success(null)
            }
            "luminosite" -> {
                // -1 : rend la main au réglage du système
                val v = appel.argument<Double>("valeur")
                val attrs = window.attributes
                if (v != null) {
                    attrs.screenBrightness = if (v < 0) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    else v.toFloat().coerceIn(0.01f, 1f)
                    window.attributes = attrs
                }
                val actuelle = window.attributes.screenBrightness
                res.success(
                    if (actuelle >= 0) actuelle.toDouble()
                    else try {
                        Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
                    } catch (e: Exception) {
                        0.5
                    },
                )
            }
            "lireTexte" -> enFond(res) {
                contentResolver.openInputStream(Uri.parse(appel.argument<String>("uri")!!))?.use {
                    it.readBytes().toString(Charsets.UTF_8)
                }
            }
            "installerApk" -> {
                // Android demande une autorisation par app avant d'installer un APK
                if (!packageManager.canRequestPackageInstalls()) {
                    lancer(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")), res)
                    return
                }
                val apk = File(appel.argument<String>("chemin")!!)
                val uri = FileProvider.getUriForFile(this, "$packageName.fichiers", apk)
                val i = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                lancer(i, res)
            }
            "peutInstaller" -> res.success(packageManager.canRequestPackageInstalls())
            "demanderNotifications" -> {
                if (android.os.Build.VERSION.SDK_INT >= 33) {
                    requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 7)
                }
                res.success(null)
            }
            else -> res.notImplemented()
        }
    }

    private fun lancer(i: Intent, res: MethodChannel.Result) {
        try {
            startActivity(i)
            res.success(true)
        } catch (e: Exception) {
            res.error("erreur", "Aucune application pour ouvrir ce fichier", null)
        }
    }

    private fun demarrerMoteur() {
        YoutubeDL.getInstance().init(applicationContext)
        FFmpeg.getInstance().init(applicationContext)
    }

    private fun initialiser(): Map<String, Any?> {
        if (!pret) {
            try {
                demarrerMoteur()
            } catch (e: Throwable) {
                // Moteur extrait à moitié (app tuée pendant le 1er lancement, mise à jour ratée…) :
                // on efface Python/ffmpeg/yt-dlp extraits et on recommence, sans que
                // l'utilisateur ait à vider le cache lui-même.
                File(noBackupFilesDir, "youtubedl-android").deleteRecursively()
                demarrerMoteur()
            }
            pret = true
        }
        return mapOf(
            "version" to YoutubeDL.getInstance().versionName(applicationContext),
            "versionApp" to packageManager.getPackageInfo(packageName, 0).versionName,
            "abi" to (android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
            "fichiers" to filesDir.absolutePath,
            "cache" to cacheDir.absolutePath,
            "travail" to (getExternalFilesDir("travail") ?: File(filesDir, "travail")).absolutePath,
        )
    }

    /** Lance yt-dlp. Avec `flux`, chaque ligne (stdout + stderr) part en événement. */
    private fun executer(appel: MethodCall, res: MethodChannel.Result) {
        val id = appel.argument<String>("id")!!
        val args = appel.argument<List<String>>("args")!!
        val flux = appel.argument<Boolean>("flux") == true
        pool.execute {
            val requete = YoutubeDLRequest(emptyList<String>()).addCommands(args)
            try {
                val r = if (flux) {
                    YoutubeDL.getInstance().execute(requete, id, true) { _, _, ligne ->
                        emettre(mapOf("type" to "ligne", "id" to id, "ligne" to ligne))
                    }
                } else {
                    YoutubeDL.getInstance().execute(requete, id, false, null)
                }
                repondre(res, mapOf("code" to r.exitCode, "sortie" to r.out, "erreur" to r.err))
            } catch (e: YoutubeDL.CanceledException) {
                repondre(res, mapOf("code" to -1, "annule" to true, "sortie" to "", "erreur" to ""))
            } catch (e: YoutubeDLException) {
                repondre(res, mapOf("code" to 1, "sortie" to "", "erreur" to (e.message ?: "")))
            } catch (e: Throwable) {
                repondre(res, mapOf("code" to 1, "sortie" to "", "erreur" to (e.message ?: e.toString())))
            }
        }
    }

    private fun estTemporaire(f: File): Boolean {
        val n = f.name
        return n.endsWith(".part") || n.endsWith(".ytdl") || n.contains(".temp.") || n.contains("-Frag") ||
            Regex("""\.f[\w-]+\.\w+$""").containsMatchIn(n)
    }

    /** Déplace les fichiers finis du dossier de travail vers Téléchargements/YT-NEXUS. */
    private fun publier(dossier: File, sousDossier: String): List<Map<String, Any?>> {
        val resultats = mutableListOf<Map<String, Any?>>()
        if (!dossier.exists()) return resultats
        val base = (Environment.DIRECTORY_DOWNLOADS + "/YT-NEXUS/" + sousDossier).trimEnd('/')
        dossier.walkTopDown().filter { it.isFile && !estTemporaire(it) }.forEach { f ->
            val relatif = f.parentFile!!.relativeTo(dossier).path
            val chemin = if (relatif.isEmpty()) base else "$base/$relatif"
            val ext = f.extension.lowercase()
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: when (ext) {
                "mkv" -> "video/x-matroska"
                "opus" -> "audio/ogg"
                "srt", "vtt" -> "text/plain"
                else -> "application/octet-stream"
            }
            val valeurs = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, f.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$chemin/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, valeurs)
                ?: throw Exception("Impossible de créer ${f.name} dans Téléchargements")
            contentResolver.openOutputStream(uri)!!.use { sortie -> f.inputStream().use { it.copyTo(sortie) } }
            valeurs.clear()
            valeurs.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, valeurs, null, null)
            // Le nom peut avoir été changé par Android en cas de doublon
            var nom = f.name
            contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) nom = it.getString(0)
            }
            resultats.add(
                mapOf(
                    "nom" to nom, "uri" to uri.toString(), "chemin" to "$chemin/$nom",
                    "taille" to f.length(), "mime" to mime,
                )
            )
            f.delete()
        }
        dossier.deleteRecursively()
        return resultats
    }

    private fun existe(uri: Uri): Boolean = try {
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use { it.count > 0 } ?: false
    } catch (e: Exception) {
        false
    }
}
