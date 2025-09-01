class FolderInfo {
  final String path;
  final int sizeInBytes;
  final int level; // برای مدیریت تورفتگی در نمایش درختی

  bool isExpanded = false; // آیا آیتم باز شده است؟
  bool isLoading = false; // آیا در حال بارگذاری زیرشاخه‌ها است؟
  List<FolderInfo> children = []; // لیست فرزندان

  FolderInfo({
    required this.path,
    required this.sizeInBytes,
    this.level = 0,
  });

  String get readableSize {
    if (sizeInBytes < 1024 * 1024) return '${(sizeInBytes / 1024).toStringAsFixed(2)} KB';
    if (sizeInBytes < 1024 * 1024 * 1024) return '${(sizeInBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(sizeInBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}