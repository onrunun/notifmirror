package com.notifmirror.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.notifmirror.android.ui.FilterScreen
import com.notifmirror.android.ui.HomeScreen
import com.notifmirror.android.ui.PairingScreen
import com.notifmirror.android.ui.theme.NotifMirrorTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            NotifMirrorTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    Root()
                }
            }
        }
    }
}

@Composable
private fun Root() {
    var screen by remember { mutableStateOf(Screen.Home) }

    AnimatedContent(
        targetState = screen,
        label = "screen",
        transitionSpec = {
            val forward = targetState.ordinal > initialState.ordinal
            val dir = if (forward) 1 else -1
            (slideInHorizontally(tween(280)) { w -> dir * w / 6 } + fadeIn(tween(220)))
                .togetherWith(
                    slideOutHorizontally(tween(280)) { w -> -dir * w / 6 } + fadeOut(tween(180))
                )
        }
    ) { current ->
        when (current) {
            Screen.Home -> HomeScreen(
                onPair = { screen = Screen.Pairing },
                onOpenFilter = { screen = Screen.Filter }
            )
            Screen.Pairing -> PairingScreen(
                onDone = { screen = Screen.Home },
                onCancel = { screen = Screen.Home }
            )
            Screen.Filter -> FilterScreen(onBack = { screen = Screen.Home })
        }
    }
}

private enum class Screen { Home, Pairing, Filter }
