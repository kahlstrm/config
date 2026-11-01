# expo-network: state stays offline after Android lifts a network block

A blank Expo app (`create-expo-app --template blank`) with `expo-network`
58.0.4. Its screen shows `useNetworkState()`, a log of
`addNetworkStateListener` events, and a button that calls
`getNetworkStateAsync()`.

Android blocks an app's network in some states, such as a background app on
Android 15 and later (`blocked=APP_BACKGROUND` in `dumpsys netpolicy`). When
the block lifts, Android calls only `NetworkCallback.onBlockedStatusChanged`,
which `expo-network`'s `NetworkModule.kt` does not override. An app that read
its state while blocked keeps reporting no network.

## Steps

From this directory, on an Android 16 emulator (`google_apis` x86_64), with a release build:

```sh
npm install
npx expo prebuild --platform android
(cd android && ./gradlew assembleRelease)
adb install android/app/build/outputs/apk/release/app-release.apk

# Block the app's network with Android's debugging firewall chain, then start it.
adb shell cmd connectivity set-chain3-enabled true
adb shell cmd connectivity set-package-networking-enabled false com.example.expnetrepro
adb shell monkey -p com.example.expnetrepro 1
# The screen shows isConnected=false, which is correct.

adb shell cmd connectivity set-package-networking-enabled true com.example.expnetrepro
# Wait 30 seconds, then press getNetworkStateAsync.
```

Expected: a network state event with `isConnected=true` shortly after the
block lifts.

Actual: no event. `useNetworkState` stays `isConnected=false`, while
`getNetworkStateAsync` returns `isConnected=true type=WIFI`.

## Fix

```diff
     override fun onCapabilitiesChanged(network: android.net.Network, networkCapabilities: NetworkCapabilities) {
       asyncEmitNetworkState(DELAY_MS)
     }
+
+    override fun onBlockedStatusChanged(network: android.net.Network, blocked: Boolean) {
+      asyncEmitNetworkState(DELAY_MS)
+    }
```

With it, and `expo-network` built from source
(`"expo": {"autolinking": {"buildFromSource": ["expo-network"]}}` in
`package.json`), the app reports `isConnected=true` within 3 seconds of the
block lifting. Without it, the app stayed offline in 2 of 2 runs; with it, it
recovered in 2 of 2.
