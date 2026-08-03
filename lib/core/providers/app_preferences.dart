import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPreferencesStore {
  static SharedPreferences? _instance;

  static Future<void> initialize() async {
    _instance ??= await SharedPreferences.getInstance();
  }

  static SharedPreferences get instance {
    final prefs = _instance;
    if (prefs == null) {
      throw StateError(
        'SharedPreferences has not been initialized. Call initializeAppPreferences() before running the app.',
      );
    }
    return prefs;
  }
}

Future<void> initializeAppPreferences() => AppPreferencesStore.initialize();

typedef PreferenceReader<T> = T? Function(SharedPreferences prefs);
typedef PreferenceWriter<T> = Future<void> Function(SharedPreferences prefs, T value);

class PreferenceNotifier<T> extends StateNotifier<T> {
  PreferenceNotifier({
    required T defaultValue,
    required PreferenceReader<T> readValue,
    required PreferenceWriter<T> writeValue,
  })  : _writeValue = writeValue,
        super(readValue(AppPreferencesStore.instance) ?? defaultValue);

  final PreferenceWriter<T> _writeValue;

  @override
  set state(T value) {
    super.state = value;
    _save(value);
  }

  Future<void> _save(T value) async {
    try {
      await _writeValue(AppPreferencesStore.instance, value);
    } catch (_) {
      // Ignore preference write failures and keep the in-memory state.
    }
  }
}
