import 'dart:typed_data';

import 'package:appflowy_editor/src/editor/util/file_picker/file_picker_service.dart';
import 'package:file_picker/file_picker.dart' as fp;

class FilePicker implements FilePickerService {
  @override
  Future<String?> getDirectoryPath({String? title}) {
    return fp.FilePicker.getDirectoryPath(dialogTitle: title);
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    fp.FileType type = fp.FileType.any,
    List<String>? allowedExtensions,
    Function(fp.FilePickerStatus p1)? onFileLoading,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
  }) async {
    // file_picker v12: static API; pickFiles returns List<PlatformFile>.
    final List<fp.PlatformFile> files;
    if (allowMultiple) {
      files = await fp.FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        type: type,
        allowedExtensions: allowedExtensions,
        onFileLoading: onFileLoading,
        allowMultiple: true,
        withData: withData,
        withReadStream: withReadStream,
        lockParentWindow: lockParentWindow,
      );
    } else {
      final file = await fp.FilePicker.pickFile(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        type: type,
        allowedExtensions: allowedExtensions,
        onFileLoading: onFileLoading,
        lockParentWindow: lockParentWindow,
      );
      files = file == null ? const <fp.PlatformFile>[] : <fp.PlatformFile>[file];
    }

    if (files.isEmpty) {
      return null;
    }
    return FilePickerResult(files);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    fp.FileType type = fp.FileType.any,
    List<String>? allowedExtensions,
    bool lockParentWindow = false,
  }) async {
    // file_picker v12: saveFile requires bytes and returns Uri?.
    final uri = await fp.FilePicker.saveFile(
      fileName: fileName ?? 'file',
      bytes: Uint8List(0),
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      lockParentWindow: lockParentWindow,
    );
    if (uri == null) {
      return null;
    }
    return uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
  }
}
