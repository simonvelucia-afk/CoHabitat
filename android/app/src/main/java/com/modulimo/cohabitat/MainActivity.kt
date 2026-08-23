package com.modulimo.cohabitat

import android.annotation.SuppressLint
import android.os.Bundle
import android.view.View
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity
import androidx.webkit.WebViewAssetLoader

/**
 * Enveloppe de demonstration : une seule vue web, qui sert les fichiers
 * embarques dans l'APK.
 *
 * Pourquoi WebViewAssetLoader plutot qu'un file:// direct : il expose les
 * fichiers sous une origine https (appassets.androidplatform.net). Une
 * page servie en file:// est une origine opaque — localStorage y est
 * capricieux, fetch() vers un fichier voisin y est interdit, et les
 * modules ES y sont bloques. Avec l'AssetLoader, la page se comporte
 * exactement comme sur un serveur, sans qu'aucun octet ne quitte
 * l'appareil.
 *
 * L'application n'a pas la permission INTERNET (voir le manifeste) : elle
 * ne peut donc pas atteindre le reseau, meme si on le lui demandait.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val assetLoader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()

        webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true          // localStorage / sessionStorage
            settings.allowFileAccess = false           // tout passe par l'AssetLoader
            settings.allowContentAccess = false
            settings.mediaPlaybackRequiresUserGesture = false

            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(
                    view: WebView,
                    request: WebResourceRequest
                ): WebResourceResponse? = assetLoader.shouldInterceptRequest(request.url)

                // Rien ne doit sortir de l'application : un lien externe
                // est ignore plutot que d'ouvrir une page blanche.
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest
                ): Boolean {
                    val hote = request.url.host
                    return hote != "appassets.androidplatform.net"
                }
            }
        }

        setContentView(webView)
        masquerBarres()

        // Le fragment #demo fait entrer l'application directement en mode
        // demonstration, sur le jeu de donnees embarque.
        webView.loadUrl("https://appassets.androidplatform.net/assets/index.html#demo")
    }

    /** Plein ecran : la demonstration se presente sans barres systeme. */
    private fun masquerBarres() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            )
    }

    /** Le bouton retour navigue dans la page avant de quitter. */
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }
}
