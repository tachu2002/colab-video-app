#!/bin/bash
# プラグインのcompileSdkを36に引き上げる
if [ -f android/build.gradle.kts ]; then
cat >> android/build.gradle.kts <<'EOT'

subprojects {
    val fixSdk = Action<Project> {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)?.compileSdkVersion(36)
    }
    if (state.executed) fixSdk.execute(this) else afterEvaluate(fixSdk)
}
EOT
else
cat >> android/build.gradle <<'EOT'

subprojects {
    afterEvaluate { p ->
        if (p.hasProperty('android')) { p.android.compileSdkVersion 36 }
    }
}
EOT
fi
tail -12 android/build.gradle* | head -30
