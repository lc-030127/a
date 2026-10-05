#!/bin/bash
set -e

mkdir -p PerfDogLite/app/src/main/java/com/example/perfdoglite
mkdir -p PerfDogLite/app/src/main/res/layout

cat > PerfDogLite/settings.gradle.kts <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "PerfDogLite"
include(":app")
EOF

cat > PerfDogLite/build.gradle.kts <<'EOF'
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
}
EOF

cat > PerfDogLite/gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
android.nonTransitiveRClass=true
EOF

cat > PerfDogLite/app/build.gradle.kts <<'EOF'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.perfdoglite"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.perfdoglite"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
}
EOF

cat > PerfDogLite/app/src/main/AndroidManifest.xml <<'EOF'
<？XML version="1.0"encoding="utf-8"？>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.PACKAGE_USAGE_STATS"
        tools:ignore="ProtectedPermissions" />
    <uses-permission android:name="android.permission.BATTERY_STATS"
        tools:ignore="ProtectedPermissions" />
    <uses-permission android:name="android.permission.READ_BATTERY_STATS"
        tools:ignore="ProtectedPermissions" />
    <uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"
        tools:ignore="QueryAllPackagesPermission" />

    <application
        android:allowBackup="true"
        android:icon="@android:drawable/sym_def_app_icon"
        android:label="PerfDog Lite"
        android:theme="@style/Theme.Material3.DayNight">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".FloatWindowService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="performance_monitor" />
        </service>
    </application>
</manifest>
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/DataModels.kt <<'EOF'
package com.example.perfdoglite

data class PerfSnapshot(
    val fps: Int = 0,
    val cpuSystemPercent: Float = 0f,
    val cpuAppPercent: Float = 0f,
    val memPssMB: Int = 0,
    val tempBatteryC: Float = 0f,
    val tempSocC: Float = 0f,
    val currentMa: Int = -1,
    val voltageMv: Int = 0,
    val rxKBps: Long = 0L,
    val txKBps: Long = 0L,
) {
    fun toDisplayText(appName: String): String {
        val pwr = if (currentMa >= 0) "${currentMa}mA" else "${voltageMv}mV"
        val tempSuffix = if (tempSocC > 0) "/${tempSocC.toInt()}℃" else ""
        return "$appName\n" +
            "FPS: $fps  CPU: ${cpuSystemPercent.toInt()}/${cpuAppPercent.toInt()}%\n" +
            "MEM: ${memPssMB}MB  TEMP: ${tempBatteryC.toInt()}℃$tempSuffix\n" +
            "PWR: $pwr  NET: ↓${rxKBps}K ↑${txKBps}K"
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/FpsMonitor.kt <<'EOF'
package com.example.perfdoglite

import android.os.Handler
import android.os.Looper
import android.view.Choreographer

class FpsMonitor {
    private val handler = Handler(Looper.getMainLooper())
    private var frameCount = 0
    private var lastSampleTime = 0L
    @Volatile var fps = 0
        private set

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            frameCount++
            val now = System.currentTimeMillis()
            if (lastSampleTime == 0L) lastSampleTime = now
            if (now - lastSampleTime >= 1000) {
                fps = (frameCount * 1000 / (now - lastSampleTime)).toInt()
                frameCount = 0
                lastSampleTime = now
            }
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    fun start() {
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    fun stop() {
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        handler.removeCallbacksAndMessages(null)
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/CpuMonitor.kt <<'EOF'
package com.example.perfdoglite

import java.io.File

class CpuMonitor {
    private var lastSystemTotal = 0L
    private var lastSystemIdle = 0L
    private var lastAppTotal = 0L
    private var lastAppPid = -1

    fun sample(pid: Int): Pair<Float, Float> {
        val sys = readSystemCpu()
        var app = 0f
        if (pid > 0 && pid == lastAppPid && lastSystemTotal > 0) {
            val appNow = readAppCpu(pid)
            val dt = (sys.first - lastSystemTotal).coerceAtLeast(1)
            val dtApp = appNow - lastAppTotal
            app = (dtApp.toFloat() / dt * 100f).coerceIn(0f, 100f)
            lastAppTotal = appNow
        }
        val sysPct = if (lastSystemTotal > 0) {
            val dt = (sys.first - lastSystemTotal).coerceAtLeast(1)
            val idle = sys.second - lastSystemIdle
            ((dt - idle).toFloat() / dt * 100f).coerceIn(0f, 100f)
        } else 0f
        lastSystemTotal = sys.first
        lastSystemIdle = sys.second
        lastAppPid = pid
        if (pid > 0 && lastAppTotal == 0L) lastAppTotal = readAppCpu(pid)
        return sysPct to app
    }

    private fun readSystemCpu(): Pair<Long, Long> {
        val line = File("/proc/stat").readLines().firstOrNull { it.startsWith("cpu ") }
            ?: return 0L to 0L
        val parts = line.split(Regex("\\s+")).drop(1).mapNotNull { it.toLongOrNull() }
        if (parts.size < 5) return 0L to 0L
        val idle = parts[3] + (parts.getOrNull(4) ?: 0L)
        return parts.sum() to idle
    }

    private fun readAppCpu(pid: Int): Long {
        return try {
            val line = File("/proc/$pid/stat").readText().substringAfterLast(')').trim()
            val parts = line.split(Regex("\\s+"))
            (parts.getOrNull(11)?.toLongOrNull() ?: 0L) +
                (parts.getOrNull(12)?.toLongOrNull() ?: 0L)
        } catch (_: Exception) {
            0L
        }
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/MemoryMonitor.kt <<'EOF'
package com.example.perfdoglite

import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Debug
import android.os.Process

class MemoryMonitor(private val context: Context) {

    fun samplePss(pkg: String): Int {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE)
            as android.app.ActivityManager
        val pid = findPid(pkg) ?: return -1
        return try {
            val infos = am.getProcessMemoryInfo(intArrayOf(pid))
            if (infos.isNotEmpty()) infos[0].totalPss / 1024 else -1
        } catch (_: Exception) {
            -1
        }
    }

    private fun findPid(pkg: String): Int? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE)
            as android.app.ActivityManager
        am.runningAppProcesses?.forEach {
            if (it.processName == pkg || it.pkgList.contains(pkg)) return it.pid
        }
        try {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
                as UsageStatsManager
            val end = System.currentTimeMillis()
            val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, end - 3600_000, end)
            val recent = stats?.filter { it.packageName == pkg }
                ?.maxByOrNull { it.lastTimeUsed } ?: return null
            if (recent.lastTimeUsed > 0) return Process.myPid()
        } catch (_: Exception) { }
        return null
    }

    fun sampleSelfPss(): Int {
        val info = Debug.MemoryInfo()
        Debug.getMemoryInfo(info)
        return info.totalPss / 1024
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/ThermalMonitor.kt <<'EOF'
package com.example.perfdoglite

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import java.io.File

class ThermalMonitor(private val context: Context) {

    private val batteryManager = context.getSystemService(Context.BATTERY_SERVICE)
        as BatteryManager

    fun batteryTemp(): Float {
        val intent = context.registerReceiver(
            null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        val raw = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        return if (raw > 0) raw / 10f else 0f
    }

    fun socTemp(): Float {
        return try {
            val zones = File("/sys/class/thermal").listFiles()
                ?.filter { it.name.startsWith("thermal_zone") } ?: emptyList()
            var best = 0f
            for (zone in zones) {
                val type = File(zone, "type").takeIf { it.exists() }?.readText()?.trim() ?: ""
                if (type.contains("cpu") || type.contains("soc") ||
                    type.contains("big") || type.contains("cluster")) {
                    val t = File(zone, "temp").takeIf { it.exists() }
                        ?.readText()?.trim()?.toIntOrNull()
                    if (t != null) best = maxOf(best, t / 1000f)
                }
            }
            best
        } catch (_: Exception) {
            0f
        }
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/PowerMonitor.kt <<'EOF'
package com.example.perfdoglite

import android.content.Context
import android.os.BatteryManager

class PowerMonitor(private val context: Context) {

    private val batteryManager = context.getSystemService(Context.BATTERY_SERVICE)
        as BatteryManager

    fun sample(): Triple<Int, Int, Int> {
        val current = try {
            batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        } catch (_: Exception) {
            Int.MIN_VALUE
        }
        val currentMa = if (current > 0) current / 1000 else -1

        val voltage = try {
            batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_VOLTAGE_NOW)
        } catch (_: Exception) {
            0
        }
        val level = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return Triple(currentMa, voltage, level)
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/NetworkMonitor.kt <<'EOF'
package com.example.perfdoglite

import android.net.TrafficStats

class NetworkMonitor {

    private var lastRx = -1L
    private var lastTx = -1L
    private var lastTime = 0L

    fun sample(uid: Int): Pair<Long, Long> {
        val now = System.currentTimeMillis()
        val rx = if (uid > 0) {
            try { TrafficStats.getUidRxBytes(uid) } catch (_: Exception) { -1L }
        } else -1L
        val tx = if (uid > 0) {
            try { TrafficStats.getUidTxBytes(uid) } catch (_: Exception) { -1L }
        } else -1L
        val rxBase = if (rx >= 0) rx else TrafficStats.getTotalRxBytes()
        val txBase = if (tx >= 0) tx else TrafficStats.getTotalTxBytes()

        if (lastRx < 0 || lastTime == 0L) {
            lastRx = rxBase
            lastTx = txBase
            lastTime = now
            return 0L to 0L
        }
        val dt = (now - lastTime).coerceAtLeast(1) / 1000f
        val rxKBps = ((rxBase - lastRx).coerceAtLeast(0) / dt / 1024).toLong()
        val txKBps = ((txBase - lastTx).coerceAtLeast(0) / dt / 1024).toLong()
        lastRx = rxBase
        lastTx = txBase
        lastTime = now
        return rxKBps to txKBps
    }
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/FloatWindowService.kt <<'EOF'
package com.example.perfdoglite

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView

class FloatWindowService : Service() {

    companion object {
        const val EXTRA_PKG = "extra_pkg"
        const val EXTRA_LABEL = "extra_label"
    }

    private lateinit var windowManager: WindowManager
    private lateinit var floatView: View
    private lateinit var textView: TextView
    private val handler = Handler(Looper.getMainLooper())

    private var targetPkg: String = ""
    private var targetLabel: String = ""
    private var targetUid: Int = -1
    private var targetPid: Int = -1

    private val fpsMonitor = FpsMonitor()
    private val cpuMonitor = CpuMonitor()
    private val thermalMonitor = ThermalMonitor(this)
    private val powerMonitor = PowerMonitor(this)
    private val networkMonitor = NetworkMonitor()
    private val memoryMonitor = MemoryMonitor(this)

    private val sampleRunnable = object : Runnable {
        override fun run() {
            refreshTarget()
            val snapshot = collect()
            textView.text = snapshot.toDisplayText(targetLabel)
            handler.postDelayed(this, 1000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        targetPkg = intent?.getStringExtra(EXTRA_PKG) ?: ""
        targetLabel = intent?.getStringExtra(EXTRA_LABEL) ?: targetPkg
        startForeground(1, android.app.Notification.Builder(this, "perf")
            .setContentTitle("PerfDog Lite")
            .setContentText("正在监控 $targetLabel")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .build())
        if (!::floatView.isInitialized) {
            addFloatView()
            fpsMonitor.start()
            handler.post(sampleRunnable)
        }
        return START_STICKY
    }

    private fun addFloatView() {
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 16
            y = 200
        }
        textView = TextView(this).apply {
            text = "PerfDog Lite 启动中…"
            textSize = 11f
            setTextColor(0xFF00E5FF.toInt())
            setBackgroundColor(0xCC101820.toInt())
            setPadding(12, 8, 12, 8)
        }
        floatView = textView
        floatView.setOnTouchListener(::dragTouch)
        windowManager.addView(floatView, params)
    }

    private fun dragTouch(v: View, event: MotionEvent): Boolean {
        val params = floatView.layoutParams as WindowManager.LayoutParams
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                v.tag = event.rawX to event.rawY
            }
            MotionEvent.ACTION_MOVE -> {
                val (sx, sy) = v.tag as Pair<Float, Float>
                params.x += (event.rawX - sx).toInt()
                params.y += (event.rawY - sy).toInt()
                v.tag = event.rawX to event.rawY
                windowManager.updateViewLayout(floatView, params)
            }
        }
        return true
    }

    private fun refreshTarget() {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val proc = am.runningAppProcesses?.firstOrNull {
            it.processName == targetPkg || it.pkgList.contains(targetPkg)
        }
        if (proc != null) {
            targetPid = proc.pid
            targetUid = proc.uid
        } else {
            targetPid = -1
        }
    }

    private fun collect(): PerfSnapshot {
        val (sysCpu, appCpu) = cpuMonitor.sample(targetPid)
        val mem = memoryMonitor.samplePss(targetPkg)
        val (ma, mv, _) = powerMonitor.sample()
        val (rx, tx) = networkMonitor.sample(targetUid)
        return PerfSnapshot(
            fps = fpsMonitor.fps,
            cpuSystemPercent = sysCpu,
            cpuAppPercent = appCpu,
            memPssMB = mem,
            tempBatteryC = thermalMonitor.batteryTemp(),
            tempSocC = thermalMonitor.socTemp(),
            currentMa = ma,
            voltageMv = mv,
            rxKBps = rx,
            txKBps = tx
        )
    }

    private fun createNotificationChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel("perf", "PerfDog Lite",
                NotificationManager.IMPORTANCE_LOW)
        )
    }

    override fun onDestroy() {
        fpsMonitor.stop()
        handler.removeCallbacks(sampleRunnable)
        if (::floatView.isInitialized) {
            try { windowManager.removeView(floatView) } catch (_: Exception) { }
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
EOF

cat > PerfDogLite/app/src/main/java/com/example/perfdoglite/MainActivity.kt <<'EOF'
package com.example.perfdoglite

import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
导入android.os.Bundle
导入android.provider.Settings
导入android.widget.ArrayAdapter
导入android.widget.Button
导入android.widget.ListView
导入android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

类MainActivity:AppCompatActivity(){

私有数据类AppItem(val标签：String，val包装：String)
私有值Applist=mutableListOf<AppItem>()
private var selectedApp:AppItem？=null

override fun onCreate(savedInstanceState:Bundle？){
super.onCreate(savedInstanceState)
setContentView(R.layout.activity_main)

Val listView=findViewById<ListView>(R.id.appList)
Val btnStart=findViewById<Button>(R.id.btnStart)
Val btnStop=findViewById<Button>(R.id.btnStop)

btnStart.setOnClickListener{
if(！Settings.canDrawOverlays(this)){
startActivity(意图(
Settings.ACTION_MANAGE_OVERLAY_PERMISSION，
Uri.parse("包：$packageName")
                ))
Toast.makeText(this，"请先开启悬浮窗权限"，Toast.LENGTH_SHORT).show()
return@setOnClickListener
            }
if(！hasUsageAccess()){
startActivity(目的(设置.action_USAGE_ACCESS_SETTINGS))
Toast.makeText(this，"请开启"使用情况访问"以读取目标App数据"，
Toast.LENGTH_LONG).show()
return@setOnClickListener
            }
if(selectedApp==null){
Toast.makeText(this，"请先选择一个目标应用程序"，Toast.LENGTH_SHORT).show()
return@setOnClickListener
            }
startMonitor(selectedApp！！)
        }

btnStop.setOnClickListener{
stopService(目的(this，FloatWindowService：：class.java))
Toast.makeText(this，"已停止监控"，Toast.LENGTH_SHORT).show()
        }

loadApps()
listView.adapter=ArrayAdapter(
这个，android.R.layout.simple_list_item_1，
Applist.地图{它.标签+"("+它.pkg+")"}
回声
ListView.setOnItemClickListener
selectedApp=Applist[POS]
吐司面包.makeText(这，
        
}

回声
Val pm=packageManager
Val intent=intent(Intent.action_MAIN).addcategory(意向.category_LAUNCHER)
Val resolved=pm.QueryIntentActivities(intent，PackageManager。match_ALL)
.sortedBy{it.loadLabel(pm).toString()}
appList.clear()
resolved.forEach{
val标签=it.loadLabel(pm).toString()
Val pkg=it.activityInfo.packageName
if(pkg！=packageName)appList.add(AppItem(标签，包装))
}
}

私人趣味有UsageAccess()：布尔值{
Val USM=作为UsageStatsManager的getSystemService(Context.Usage_STATS_SERVICE)
Val end=System.currentTimeMillis()
Val stats=USM.QueryUsageStats(UsageStatsManager.Interval_DAILY，end-60_000，end)
返回stats！=null&&stats.isNotEmpty()
}

私人fun startMonitor(项目：AppItem){
Valintent=Intent(此，FloatWindowService：：class.java)
            .putExtra(FloatWindowService.EXTRA_PKG, item.pkg)
.putExtra(FloatWindowService.EXTRA_LABEL，item.label)
startForegroundService(intent)
Toast.makeText(this，"开始监控${项.标签}"，Toast.LENGTH_SHORT).show()
}
}
EOF

cat>PerfDogLite/app/src/main/res/layout/activity_main.xml<<'EOF'<<'EOF'
<？XML版本="1.0"编码="UTF-8"？>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
Android:layout_width="match_parent"
    android:layout_height="match_parent"
安卓：方向=“垂直”
Android:padding="16dp">

<文本视图
Android:layout_width="match_parent"
android:layout_height="wrap_content"
Android:text="选择要监控的App(点选后点"开始监控")"
Android:textSize="15sp"
Android:paddingBottom="8DP"/>

<ListView
Android:id="@+id/Applist"
Android:layout_width="match_parent"
android:layout_height="0dp"
android:layout_weight="1"/>

<LinearLayout
Android:layout_width="match_parent"
android:layout_height="wrap_content"
安卓：方向=“水平”
Android:paddingTop="12dp">

<按钮
android:id="@+id/btnStart"
Android:layout_width="0dp"
android:layout_height="wrap_content"
android:layout_weight="1"
Android:text="开始监控"/>

<按钮
Android:id="@+id/btnStop"
Android:layout_width="0dp"
android:layout_height="wrap_content"
android:layout_weight="1"
Android:text="停止监控"/>
</LinearLayout>
</LinearLayout>
EOF

回声"项目文件生成完毕""项目文件生成完毕"
