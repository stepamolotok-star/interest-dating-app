import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../theme.dart';
import 'common.dart';

/// Фото по id: своё или чужое. Пока грузится — фон, не загрузилось — значок.
class PhotoView extends StatelessWidget {
  const PhotoView(this.id, {super.key, this.fit = BoxFit.cover});

  final String id;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final api = AppScope.read(context).api;
    return ColoredBox(
      color: AppColors.line,
      child: Image(
        image: api.photo(id),
        fit: fit,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, sync) => sync
            ? child
            : AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: child,
              ),
        errorBuilder: (context, error, stack) =>
            Center(child: Icon(Icons.image_not_supported_outlined, color: AppColors.muted)),
      ),
    );
  }
}

/// Фото человека в карточке: листаются вбок, точки показывают, сколько их.
class PhotoCarousel extends StatefulWidget {
  const PhotoCarousel({super.key, required this.photos, this.screenShare = 0.42, this.caption = ''});

  final List<String> photos;

  /// Подпись поверх нижнего края (имя и возраст).
  final String caption;

  /// Не выше этой доли экрана: под фото должно остаться видно, что у вас общего.
  final double screenShare;

  @override
  State<PhotoCarousel> createState() => _PhotoCarouselState();
}

class _PhotoCarouselState extends State<PhotoCarousel> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final maxH = MediaQuery.sizeOf(context).height * widget.screenShare;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: LayoutBuilder(
        builder: (context, c) => SizedBox(
          width: c.maxWidth,
          height: (c.maxWidth * 5 / 4).clamp(0, maxH).toDouble(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                key: const Key('photo-carousel'),
                itemCount: photos.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => PhotoView(photos[i]),
              ),
              if (widget.caption.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 32, 16, 12),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0x99000000)],
                        ),
                      ),
                      child: Text(
                        widget.caption,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22),
                      ),
                    ),
                  ),
                ),
              if (photos.length > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 10,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < photos.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _page ? 22 : 8,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: i == _page ? 0.95 : 0.55),
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 2)],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Откуда взять фото. Подменяется в тестах.
typedef PhotoPicker = Future<Uint8List?> Function(ImageSource source);

Future<Uint8List?> _systemPicker(ImageSource source) async {
  // Уменьшаем ещё на телефоне: загрузка быстрее, сервер всё равно перекодирует.
  final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
  return file?.readAsBytes();
}

/// Свои фото: до 6, первое — главное. Нажатие на пустое место — добавить,
/// на фото — сделать главным или удалить.
class PhotosEditor extends StatefulWidget {
  const PhotosEditor({super.key});

  static const max = 6;

  /// Выбор фото; в тестах подменяется.
  static PhotoPicker pick = _systemPicker;

  @override
  State<PhotosEditor> createState() => _PhotosEditorState();
}

class _PhotosEditorState extends State<PhotosEditor> {
  bool _uploading = false;

  Future<void> _add() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('photo-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Выбрать из галереи'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              key: const Key('photo-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Сделать снимок'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final Uint8List? bytes;
    try {
      bytes = await PhotosEditor.pick(source);
    } catch (e) {
      if (mounted) {
        showError(context, const ApiException(0, 'Не получилось открыть фото. Проверьте доступ к галерее или камере.'));
      }
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      await AppScope.read(context).addPhoto(bytes);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _manage(String id, bool main) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!main)
              ListTile(
                key: const Key('photo-main'),
                leading: const Icon(Icons.star_outline),
                title: const Text('Сделать главным'),
                subtitle: const Text('Его видят первым в ленте и в переписке'),
                onTap: () => Navigator.pop(context, 'main'),
              ),
            ListTile(
              key: const Key('photo-delete'),
              leading: Icon(Icons.delete_outline, color: AppColors.error),
              title: Text('Удалить', style: TextStyle(color: AppColors.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final state = AppScope.read(context);
    try {
      if (action == 'main') await state.makeMainPhoto(id);
      if (action == 'delete') await state.deletePhoto(id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final photos = AppScope.of(context).photos;
    final t = Theme.of(context).textTheme;
    final slots = PhotosEditor.max;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: slots,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 3 / 4,
      ),
      itemBuilder: (context, i) {
        final radius = BorderRadius.circular(14);
        if (i < photos.length) {
          final p = photos[i];
          return Material(
            key: Key('photo-$i'),
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _manage(p.id, i == 0),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PhotoView(p.id),
                  if (i == 0)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: AppColors.fill, borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          'Главное',
                          style: t.labelSmall?.copyWith(color: AppColors.onFill, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        final next = i == photos.length;
        return Material(
          key: Key('photo-slot-$i'),
          color: next ? AppColors.accentTint : AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: next ? AppColors.accent : AppColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _uploading ? null : _add,
            child: Center(
              child: next && _uploading
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_a_photo_outlined, color: next ? AppColors.accent : AppColors.muted),
                        if (i == 0) ...[
                          const SizedBox(height: 6),
                          Text('Добавить', style: t.labelMedium?.copyWith(color: AppColors.accent)),
                        ],
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}
