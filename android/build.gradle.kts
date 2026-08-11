plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.detekt)
}

detekt {
    config.from(files("config/detekt/detekt.yml"))
    buildUponDefaultConfig = true
    baseline = file("config/detekt/baseline.xml")
    parallel = true
    allRules = false
}

tasks.withType<io.gitlab.arturbosch.detekt.Detekt>().configureEach {
    source = fileTree("app/src/main/kotlin") + fileTree("app/src/test/kotlin")
    exclude("**/build/**")
}

tasks.withType<io.gitlab.arturbosch.detekt.DetektCreateBaselineTask>().configureEach {
    source = fileTree("app/src/main/kotlin") + fileTree("app/src/test/kotlin")
    exclude("**/build/**")
}
