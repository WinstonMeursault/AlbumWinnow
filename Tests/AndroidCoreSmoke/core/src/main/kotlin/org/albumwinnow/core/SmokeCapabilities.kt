package org.albumwinnow.core

// The smoke host has native pixel decoding but no production scene model.
// Controlled scene providers in androidTest only exercise the shared Rust rules.
object SmokeCapabilities {
    val sceneProvider: CoreSceneProvider? = null
}
