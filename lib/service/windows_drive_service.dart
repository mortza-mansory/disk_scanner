// lib/services/windows_drive_service.dart

import 'dart:io';

// یک کلاس ساده برای نگهداری اطلاعات بازگشتی
class DriveInfo {
  final double totalGB;
  final double freeGB;
  DriveInfo({required this.totalGB, required this.freeGB});
}

class WindowsDriveService {
  static Future<DriveInfo?> getDriveInfo(String driveLetter) async {
    // اطمینان حاصل می‌کنیم که فقط حرف درایو ارسال شود (مثلا C:)
    if (!driveLetter.endsWith(r':\')) return null;
    final deviceId = driveLetter.substring(0, 2);

    try {
      // اجرای دستور WMIC
      final result = await Process.run('wmic', [
        'logicaldisk',
        'where',
        'DeviceID="$deviceId"',
        'get',
        'FreeSpace,Size',
        '/value'
      ]);

      if (result.exitCode != 0) {
        print('WMIC Error: ${result.stderr}');
        return null; // دستور با خطا مواجه شد
      }

      // پردازش خروجی متنی
      final stdout = result.stdout as String;
      final lines = stdout.trim().split('\n');

      double? freeSpaceBytes;
      double? sizeBytes;

      for (var line in lines) {
        final parts = line.split('=');
        if (parts.length == 2) {
          final key = parts[0].trim();
          final value = double.tryParse(parts[1].trim());
          if (value != null) {
            if (key == 'FreeSpace') freeSpaceBytes = value;
            if (key == 'Size') sizeBytes = value;
          }
        }
      }

      if (freeSpaceBytes != null && sizeBytes != null) {
        const bytesInGB = 1024 * 1024 * 1024;
        return DriveInfo(
          totalGB: sizeBytes / bytesInGB,
          freeGB: freeSpaceBytes / bytesInGB,
        );
      }

    } catch (e) {
      print('Failed to run WMIC process: $e');
    }

    return null; // در صورت بروز هرگونه خطا
  }
}