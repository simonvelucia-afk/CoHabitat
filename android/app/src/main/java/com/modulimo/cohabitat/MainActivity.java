package com.modulimo.cohabitat;

import android.annotation.SuppressLint;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.appcompat.app.AppCompatActivity;
import androidx.webkit.WebViewAssetLoader;

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
 *
 * Ecrit en Java et non en Kotlin : cette classe n'utilise aucune
 * particularite du langage, alors que le greffon Kotlin impose un
 * compilateur supplementaire dont la version doit s'accorder avec celle
 * du JDK d'Android Studio. Cet accord s'est revele fragile — « Daemon
 * compilation failed » sur un Android Studio recent — pour un benefice
 * nul sur 90 lignes d'appels a l'API Android.
 */
public class MainActivity extends AppCompatActivity {

    private static final String HOTE = "appassets.androidplatform.net";

    private WebView webView;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        final WebViewAssetLoader assetLoader = new WebViewAssetLoader.Builder()
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();

        webView = new WebView(this);

        WebSettings reglages = webView.getSettings();
        reglages.setJavaScriptEnabled(true);
        reglages.setDomStorageEnabled(true);          // localStorage / sessionStorage
        reglages.setAllowFileAccess(false);           // tout passe par l'AssetLoader
        reglages.setAllowContentAccess(false);
        reglages.setMediaPlaybackRequiresUserGesture(false);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView vue, WebResourceRequest requete) {
                return assetLoader.shouldInterceptRequest(requete.getUrl());
            }

            // Un lien externe est confie au navigateur du systeme, pas
            // charge dans la vue web : l'application n'a pas la permission
            // INTERNET et n'en tirerait qu'une page blanche.
            //
            // Auparavant il etait simplement ignore, ce qui donnait un lien
            // mort — toucher le logo Modulimo ne faisait rien. Le passer au
            // navigateur ouvre bien la page sans donner pour autant le
            // reseau a l'application.
            @Override
            public boolean shouldOverrideUrlLoading(WebView vue, WebResourceRequest requete) {
                Uri url = requete.getUrl();
                if (HOTE.equals(url.getHost())) return false;   // page embarquee
                try {
                    Intent navigateur = new Intent(Intent.ACTION_VIEW, url);
                    navigateur.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    MainActivity.this.startActivity(navigateur);
                } catch (ActivityNotFoundException e) {
                    // Aucun navigateur installe : ne rien faire plutot que
                    // laisser l'application s'arreter.
                }
                return true;
            }
        });

        setContentView(webView);
        masquerBarres();

        // Le fragment #demo fait entrer l'application directement en mode
        // demonstration, sur le jeu de donnees embarque.
        webView.loadUrl("https://" + HOTE + "/assets/index.html#demo");
    }

    /** Plein ecran : la demonstration se presente sans barres systeme. */
    @SuppressWarnings("deprecation")
    private void masquerBarres() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    /** Le bouton retour navigue dans la page avant de quitter. */
    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }
}
