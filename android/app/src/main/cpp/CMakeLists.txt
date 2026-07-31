cmake_minimum_required(VERSION 3.22.1)
project("wjplayer_native")

find_library(log-lib log)

# ============================================================================
# JNI 初始化桥接层
# 在 JNI_OnLoad 中注册 JavaVM，确保 mpv 视频输出能访问 JVM
# 必须在 libmpv.so 和 libplayer.so 之前加载
# ============================================================================

add_library(mpv_init_jni SHARED
    mpv_init_jni.cpp
)

target_link_libraries(mpv_init_jni
    ${log-lib}
)

target_compile_features(mpv_init_jni PUBLIC cxx_std_17)

# ============================================================================
# libass JNI 桥接层
# ============================================================================

add_library(linass_jni SHARED
    linass_jni.cpp
)

target_link_libraries(linass_jni
    ${log-lib}
    dl
)

target_compile_features(linass_jni PUBLIC cxx_std_17)
