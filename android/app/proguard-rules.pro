# Room 2.6.1 (used by WorkManager) loads generated databases by reflection.
# R8 full mode does not implicitly retain their no-argument constructors.
# Matches the explicit constructor rule added by AndroidX Room upstream.
-keep class * extends androidx.room.RoomDatabase {
    <init>();
}
