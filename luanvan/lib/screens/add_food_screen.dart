import 'package:collection/collection.dart';
import 'dart:convert';
import 'dart:core';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as imageLib;
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';
import 'config.dart';

class AddFoodScreen extends StatefulWidget {
  final String uid;
  final String token;
  final bool isDarkMode;
  final String fridgeId;

  const AddFoodScreen({
    super.key,
    required this.uid,
    required this.token,
    required this.isDarkMode,
    required this.fridgeId,
  });

  @override
  _AddFoodScreenState createState() => _AddFoodScreenState();
}

class _AddFoodScreenState extends State<AddFoodScreen> with TickerProviderStateMixin {
  late final AnimationController _animationController;
  late final AnimationController _headerAnimationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _headerSlideAnimation;

  final _picker = ImagePicker();
  File? _image;
  String? _imagePath;
  final _nameController = TextEditingController();
  final _quantityController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _unitId;
  String? _selectedCategoryId;
  DateTime _expiryDate = DateTime.now().add(const Duration(days: 7));
  String? _selectedAreaId;
  Map<String, dynamic>? _aiResult;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _modelLoaded = false;
  String? _errorMessage;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<Map<String, dynamic>> _storageAreas = [];
  List<Map<String, dynamic>> _units = [];
  List<Map<String, dynamic>> _foodCategories = [];

  drive.DriveApi? _driveApi;
  Interpreter? _interpreter;
  List<String>? _labels;

  final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      printTime: true,
    ),
  );

  final Color primaryColor = const Color(0xFF0078D7);
  final Color accentColor = const Color(0xFF00B294);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color errorColor = const Color(0xFFE74C3C);
  final Color backgroundColor = const Color(0xFFE6F7FF);
  final Color surfaceColor = Colors.white;
  final Color textPrimaryColor = const Color(0xFF202124);
  final Color textSecondaryColor = const Color(0xFF5F6368);

  Color get currentBackgroundColor => widget.isDarkMode ? const Color(0xFF121212) : backgroundColor;
  Color get currentSurfaceColor => widget.isDarkMode ? const Color(0xFF1E1E1E) : surfaceColor;
  Color get currentTextPrimaryColor => widget.isDarkMode ? const Color(0xFFE0E0E0) : textPrimaryColor;
  Color get currentTextSecondaryColor => widget.isDarkMode ? const Color(0xFFB0B0B0) : textSecondaryColor;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _initializeAnimations();
    _checkUserAuth();
    _initGoogleDrive();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initializeData();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _animationController.dispose();
    _headerAnimationController.dispose();
    _interpreter?.close();
    super.dispose();
  }

  void _initializeAnimations() {
    _headerAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _headerAnimationController, curve: Curves.easeOut),
    );
    _headerAnimationController.forward();
    _animationController.forward();
  }

  Future<void> _initializeData() async {
    _logger.i('Bắt đầu khởi tạo dữ liệu...');
    final startTime = DateTime.now();
    try {
      await Future.wait([
        _fetchInitialData(),
        _loadModel(),
      ]);
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_modelLoaded && _units.isNotEmpty && _foodCategories.isNotEmpty) {
            _animationController.forward();
            _logger.i('Khởi tạo dữ liệu thành công, thời gian: ${DateTime.now().difference(startTime).inMilliseconds}ms');
            if (_storageAreas.isEmpty) {
              _logger.w('Cảnh báo: Không có khu vực lưu trữ, vui lòng thêm khu vực lưu trữ');
              _errorMessage = 'Vui lòng thêm khu vực lưu trữ trong tủ lạnh';
              _showErrorSnackBar(_errorMessage!);
            }
          } else {
            _errorMessage = 'Không thể tải đầy đủ dữ liệu hoặc mô hình TFLite';
            if (!_modelLoaded) {
              _logger.w('Lỗi: Mô hình TFLite không được tải');
            }
            if (_storageAreas.isEmpty) {
              _logger.w('Cảnh báo: Không có khu vực lưu trữ');
              _errorMessage = 'Vui lòng thêm khu vực lưu trữ trong tủ lạnh';
            }
            if (_units.isEmpty) {
              _logger.w('Lỗi: Không có đơn vị');
            }
            if (_foodCategories.isEmpty) {
              _logger.w('Lỗi: Không có danh mục thực phẩm');
            }
            _showErrorSnackBar(_errorMessage!);
          }
        });
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi khởi tạo dữ liệu: $e', stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Lỗi khi khởi tạo dữ liệu: $e';
        });
        _showErrorSnackBar(_errorMessage!);
      }
    }
  }

  Future<void> _loadModel() async {
    try {
      _logger.i('Bắt đầu tải mô hình TFLite');
      _interpreter = await Interpreter.fromAsset('assets/fruit_vegetable_model.tflite');
      _logger.i('Mô hình TFLite đã được tải');

      final labelData = await DefaultAssetBundle.of(context).loadString('assets/labels.txt');
      _labels = labelData
          .split('\n')
          .where((label) => label.trim().isNotEmpty)
          .map((label) => label.trim().toLowerCase())
          .toList();
      _logger.i('Nội dung file labels.txt:');
      for (var label in _labels!) {
        _logger.i('Nhãn: "$label"');
      }
      if (_labels!.length != 36) {
        throw Exception('Số nhãn không đúng, yêu cầu 36 nhãn, nhận được ${_labels!.length}');
      }
      _logger.i('Đã tải ${_labels!.length} nhãn, ví dụ: ${_labels![0]}');

      final labelTranslations = {
        'apple': 'Táo',
        'banana': 'Chuối',
        'beetroot': 'Củ dền',
        'bell pepper': 'Ớt chuông',
        'cabbage': 'Bắp cải',
        'capsicum': 'Ớt chuông',
        'carrot': 'Cà rốt',
        'cauliflower': 'Súp lơ trắng',
        'chilli pepper': 'Ớt cay',
        'corn': 'Ngô',
        'cucumber': 'Dưa chuột',
        'eggplant': 'Cà tím',
        'garlic': 'Tỏi',
        'ginger': 'Gừng',
        'grapes': 'Nho',
        'jalapeno': 'Ớt Jalapeño',
        'kiwi': 'Kiwi',
        'lemon': 'Chanh',
        'lettuce': 'Xà lách',
        'mango': 'Xoài',
        'onion': 'Hành tây',
        'orange': 'Cam',
        'paprika': 'Ớt paprika',
        'pear': 'Lê',
        'peas': 'Đậu Hà Lan',
        'pineapple': 'Dứa',
        'pomegranate': 'Lựu',
        'potato': 'Khoai tây',
        'raddish': 'Củ cải đỏ',
        'soy beans': 'Đậu nành',
        'spinach': 'Rau bina',
        'sweetcorn': 'Ngô ngọt',
        'sweetpotato': 'Khoai lang',
        'tomato': 'Cà chua',
        'turnip': 'Củ cải trắng',
        'watermelon': 'Dưa hấu',
      };
      for (var label in _labels!) {
        if (!labelTranslations.containsKey(label)) {
          _logger.w('Nhãn "$label" không có trong bản đồ dịch labelTranslations');
        }
      }

      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      _logger.i('Hình dạng đầu vào: $inputShape, Hình dạng đầu ra: $outputShape');

      final expectedInputShape = [1, 224, 224, 3];
      final expectedOutputShape = [1, 36];
      if (!const ListEquality().equals(inputShape, expectedInputShape) ||
          !const ListEquality().equals(outputShape, expectedOutputShape)) {
        throw Exception('Hình dạng mô hình không đúng: input=$inputShape, output=$outputShape');
      }

      _interpreter!.allocateTensors();
      _modelLoaded = true;
      _logger.i('Mô hình TFLite đã được tải và cấp phát tensor thành công');
    } catch (e, stackTrace) {
      _modelLoaded = false;
      _logger.e('Lỗi khi tải mô hình TFLite: $e', stackTrace: stackTrace);
      throw Exception('Lỗi khi tải mô hình TFLite: $e');
    }
  }

  Future<Map<String, dynamic>> _runInference(Uint8List imageBytes) async {
    if (!_modelLoaded || _interpreter == null) {
      _logger.e('Mô hình TFLite chưa được tải');
      throw Exception('Mô hình TFLite chưa được tải');
    }

    try {
      _logger.i('Bắt đầu suy luận với dữ liệu ảnh');
      final inputTensor = _interpreter!.getInputTensor(0);
      final outputTensor = _interpreter!.getOutputTensor(0);

      final expectedInputShape = [1, 224, 224, 3];
      final inputShape = inputTensor.shape;
      if (!const ListEquality().equals(inputShape, expectedInputShape)) {
        throw Exception('Hình dạng đầu vào không đúng: $inputShape, kỳ vọng: $expectedInputShape');
      }
      _logger.i('Hình dạng đầu vào tensor: $inputShape');

      imageLib.Image? image = imageLib.decodeImage(imageBytes);
      if (image == null) {
        throw Exception('Không thể giải mã ảnh từ dữ liệu bytes');
      }

      image = imageLib.copyResize(image, width: 224, height: 224);
      if (image.width != 224 || image.height != 224) {
        throw Exception('Kích thước ảnh sau resize không đúng: ${image.width}x${image.height}');
      }

      if (image.numChannels != 3) {
        _logger.w('Ảnh không phải RGB (numChannels: ${image.numChannels}), chuyển đổi sang RGB');
        final rgbImage = imageLib.Image(width: image.width, height: image.height, numChannels: 3);
        for (int y = 0; y < image.height; y++) {
          for (int x = 0; x < image.width; x++) {
            final pixel = image.getPixel(x, y);
            final r = pixel.r;
            final g = image.numChannels >= 2 ? pixel.g : pixel.r;
            final b = image.numChannels >= 3 ? pixel.b : pixel.r;
            rgbImage.setPixelRgb(x, y, r.toInt(), g.toInt(), b.toInt());
          }
        }
        image = rgbImage;
      }

      final input = Float32List(1 * 224 * 224 * 3);
      int pixelIndex = 0;
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          final pixel = image.getPixel(x, y);
          input[pixelIndex++] = pixel.r / 255.0;
          input[pixelIndex++] = pixel.g / 255.0;
          input[pixelIndex++] = pixel.b / 255.0;
        }
      }
      final inputTensorData = input.reshape([1, 224, 224, 3]);

      final output = Float32List(1 * 36).reshape([1, 36]);
      _interpreter!.run(inputTensorData, output);

      final outputList = output[0].cast<double>();
      if (outputList.isEmpty) {
        _logger.e('Danh sách đầu ra rỗng');
        throw Exception('Danh sách đầu ra rỗng');
      }
      if (outputList.any((value) => value.isNaN || value.isInfinite)) {
        _logger.e('Đầu ra chứa giá trị không hợp lệ (NaN hoặc Infinite)');
        throw Exception('Đầu ra chứa giá trị không hợp lệ');
      }

      final maxScore = outputList.reduce((double a, double b) => a > b ? a : b);
      final maxIndex = outputList.indexWhere((value) => value == maxScore);
      final predictedLabel = _labels![maxIndex];
      final confidence = maxScore * 100;
      final translatedLabel = _translateToVietnamese(predictedLabel);
      _logger.i('Dự đoán: "$predictedLabel" -> Dịch: "$translatedLabel" với độ tin cậy: $confidence%');

      return {
        'label': translatedLabel,
        'original_label': predictedLabel,
        'confidence': confidence,
      };
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi chạy suy luận: $e', stackTrace: stackTrace);
      throw Exception('Lỗi khi chạy suy luận: $e');
    }
  }

  String _translateToVietnamese(String label) {
    final Map<String, String> labelTranslations = {
      'apple': 'Táo',
      'banana': 'Chuối',
      'beetroot': 'Củ dền',
      'bell pepper': 'Ớt chuông',
      'cabbage': 'Bắp cải',
      'capsicum': 'Ớt chuông',
      'carrot': 'Cà rốt',
      'cauliflower': 'Súp lơ trắng',
      'chilli pepper': 'Ớt cay',
      'corn': 'Ngô',
      'cucumber': 'Dưa chuột',
      'eggplant': 'Cà tím',
      'garlic': 'Tỏi',
      'ginger': 'Gừng',
      'grapes': 'Nho',
      'jalapeno': 'Ớt Jalapeño',
      'kiwi': 'Kiwi',
      'lemon': 'Chanh',
      'lettuce': 'Xà lách',
      'mango': 'Xoài',
      'onion': 'Hành tây',
      'orange': 'Cam',
      'paprika': 'Ớt paprika',
      'pear': 'Lê',
      'peas': 'Đậu Hà Lan',
      'pineapple': 'Dứa',
      'pomegranate': 'Lựu',
      'potato': 'Khoai tây',
      'raddish': 'Củ cải đỏ',
      'soy beans': 'Đậu nành',
      'spinach': 'Rau bina',
      'sweetcorn': 'Ngô ngọt',
      'sweetpotato': 'Khoai lang',
      'tomato': 'Cà chua',
      'turnip': 'Củ cải trắng',
      'watermelon': 'Dưa hấu',
    };
    final normalizedLabel = label.trim().toLowerCase();
    final translated = labelTranslations[normalizedLabel] ?? label;
    if (translated == label) {
      _logger.w('Không tìm thấy bản dịch cho nhãn: "$normalizedLabel"');
    } else {
      _logger.i('Nhãn gốc: "$label", Nhãn chuẩn hóa: "$normalizedLabel", Nhãn dịch: "$translated"');
    }
    return translated;
  }

  Future<Uint8List?> _downloadImageFromUrl(String url) async {
    _logger.i('Bắt đầu tải ảnh từ URL: $url');
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final contentType = response.headers['content-type'];
        if (contentType != 'image/jpeg' && contentType != 'image/png') {
          _logger.e('Định dạng ảnh không được hỗ trợ: $contentType');
          throw Exception('Định dạng ảnh không được hỗ trợ: $contentType');
        }
        _logger.i('Đã tải dữ liệu ảnh từ URL thành công');
        return response.bodyBytes;
      } else {
        _logger.e('Không thể tải hình ảnh từ URL: HTTP ${response.statusCode}');
        throw Exception('Không thể tải hình ảnh từ URL: HTTP ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải hình ảnh từ URL: $e', stackTrace: stackTrace);
      _showErrorSnackBar('Lỗi khi tải hình ảnh từ URL: $e');
      return null;
    }
  }

  Future<void> _initGoogleDrive() async {
    _logger.i('Bắt đầu khởi tạo Google Drive API...');
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        _logger.e('Không có kết nối mạng để khởi tạo Google Drive');
        _showErrorSnackBar('Không có kết nối mạng để khởi tạo Google Drive');
        return;
      }

      final serviceAccountCredentials = await _loadServiceAccountCredentials();
      final client = await auth.clientViaServiceAccount(
        serviceAccountCredentials,
        ['https://www.googleapis.com/auth/drive.file'],
      );
      _driveApi = drive.DriveApi(client);
      _logger.i('Đã khởi tạo Google Drive API thành công');
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi khởi tạo Google Drive: $e', stackTrace: stackTrace);
    }
  }

  Future<auth.ServiceAccountCredentials> _loadServiceAccountCredentials() async {
    _logger.i('Bắt đầu tải credentials Google Drive...');
    try {
      final credentialsJson = await rootBundle.loadString('assets/credentials.json');
      final jsonData = jsonDecode(credentialsJson);
      if (jsonData['project_id'] != 'luanvan-6bfff') {
        _logger.e('Project ID trong credentials.json không khớp: ${jsonData['project_id']}');
        throw Exception('Project ID không khớp');
      }
      _logger.i('Đã tải credentials Google Drive thành công');
      return auth.ServiceAccountCredentials.fromJson(credentialsJson);
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải credentials Google Drive: $e', stackTrace: stackTrace);
      throw Exception('Lỗi khi tải credentials Google Drive: $e');
    }
  }

  Future<void> _checkUserAuth() async {
    _logger.i('Kiểm tra trạng thái đăng nhập người dùng...');
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
        _logger.i('Đã đăng nhập ẩn danh');
      } else {
        _logger.i('Người dùng đã đăng nhập: ${user.uid}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi đăng nhập: $e', stackTrace: stackTrace);
      _showErrorSnackBar('Lỗi khi đăng nhập: $e');
    }
  }

  Future<void> _fetchInitialData() async {
    _logger.i('Bắt đầu tải dữ liệu ban đầu từ Firestore...');
    try {
      await Future.wait([
        _fetchStorageAreas(),
        _fetchUnits(),
        _fetchFoodCategories(),
      ]);
      if (_storageAreas.isEmpty || _units.isEmpty || _foodCategories.isEmpty) {
        _logger.w('Không thể tải dữ liệu: Một hoặc nhiều bộ sưu tập rỗng');
        setState(() {
          _errorMessage = 'Không thể tải dữ liệu. Một hoặc nhiều bộ sưu tập rỗng.';
        });
      } else {
        _logger.i('Đã tải toàn bộ dữ liệu Firestore thành công');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải dữ liệu ban đầu: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Lỗi khi tải dữ liệu ban đầu: $e';
      });
    }
  }

  Future<void> _fetchStorageAreas() async {
    if (widget.fridgeId.isEmpty) {
      _logger.e('fridgeId không hợp lệ hoặc rỗng');
      setState(() {
        _storageAreas = [];
        _selectedAreaId = null;
        _errorMessage = 'ID tủ lạnh không hợp lệ. Vui lòng thử lại.';
      });
      _showErrorSnackBar(_errorMessage!);
      return;
    }

    _logger.i('Đang tải khu vực lưu trữ từ API cho fridgeId: ${widget.fridgeId}...');
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        _logger.e('Không có kết nối mạng để tải khu vực lưu trữ');
        setState(() {
          _storageAreas = [];
          _selectedAreaId = null;
          _errorMessage = 'Không có kết nối mạng. Vui lòng kiểm tra kết nối.';
        });
        _showErrorSnackBar(_errorMessage!);
        return;
      }

      final url = Uri.parse('${Config.getNgrokUrl()}/get_storage_areas?userId=${Uri.encodeComponent(widget.uid)}&fridgeId=${Uri.encodeComponent(widget.fridgeId)}');
      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Yêu cầu API hết thời gian');
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data == null || data['areas'] == null) {
          _logger.e('Dữ liệu API không hợp lệ: ${response.body}');
          throw Exception('Dữ liệu khu vực lưu trữ không hợp lệ');
        }

        final areas = List<Map<String, dynamic>>.from(data['areas']);
        setState(() {
          _storageAreas = areas.map((area) {
            return {
              'id': area['id'] ?? '',
              'name': area['name'] ?? 'Unknown Area',
              'fridgeId': area['fridgeId'] ?? widget.fridgeId,
            };
          }).toList();
          _selectedAreaId = _storageAreas.isNotEmpty ? _storageAreas[0]['id'] : null;
          _errorMessage = _storageAreas.isEmpty ? 'Không tìm thấy khu vực lưu trữ. Vui lòng thêm khu vực lưu trữ.' : null;
        });

        if (_storageAreas.isEmpty) {
          _logger.w('Không tìm thấy khu vực lưu trữ cho fridgeId: ${widget.fridgeId}');
          _showErrorSnackBar('Không tìm thấy khu vực lưu trữ. Vui lòng thêm khu vực lưu trữ.');
        } else {
          _logger.i('Đã tải ${_storageAreas.length} khu vực lưu trữ: ${_storageAreas.map((e) => e['name']).join(", ")}');
        }
      } else {
        _logger.e('Lỗi khi tải khu vực lưu trữ: HTTP ${response.statusCode}, body: ${response.body}');
        throw Exception('Không thể tải khu vực lưu trữ: HTTP ${response.statusCode} - ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải khu vực lưu trữ: $e', stackTrace: stackTrace);
      setState(() {
        _storageAreas = [];
        _selectedAreaId = null;
        _errorMessage = 'Lỗi khi tải khu vực lưu trữ: $e';
      });
      _showErrorSnackBar(_errorMessage!);
    }
  }

  Future<void> _fetchUnits() async {
    _logger.i('Đang tải đơn vị từ Firestore...');
    try {
      final snapshot = await _firestore.collection('Units').get();
      setState(() {
        _units = snapshot.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList();
        _unitId ??= _units.isNotEmpty ? _units[0]['id'] : null;
      });
      _logger.i('Đã tải ${_units.length} đơn vị: ${_units.map((e) => e['name']).join(", ")}');
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải đơn vị: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Lỗi khi tải đơn vị: $e';
      });
    }
  }

  Future<void> _fetchFoodCategories() async {
    _logger.i('Đang tải danh mục thực phẩm từ Firestore...');
    try {
      final snapshot = await _firestore.collection('FoodCategories').get();
      setState(() {
        _foodCategories = snapshot.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList();
        _selectedCategoryId ??= _foodCategories.isNotEmpty ? _foodCategories[0]['id'] : null;
      });
      _logger.i('Đã tải ${_foodCategories.length} danh mục thực phẩm: ${_foodCategories.map((e) => e['name']).join(", ")}');
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải danh mục thực phẩm: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Lỗi khi tải danh mục thực phẩm: $e';
      });
    }
  }

  Future<void> _pickImage() async {
    _logger.i('Bắt đầu chọn ảnh từ thư viện...');
    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (pickedFile != null) {
        final imageBytes = await File(pickedFile.path).readAsBytes();
        setState(() {
          _image = File(pickedFile.path);
          _imagePath = pickedFile.path;
          _aiResult = null;
        });
        _logger.i('Đã chọn ảnh từ thư viện: ${pickedFile.path}');
        final result = await _runInference(imageBytes);
        if (mounted && result != null) {
          setState(() {
            _aiResult = result;
            _nameController.text = result['label'];
            _logger.i('Cập nhật _nameController.text: "${_nameController.text}"');
          });
          _logger.i('Kết quả nhận diện AI: ${result['label']} (${result['confidence'].toStringAsFixed(1)}%), Nhãn gốc: ${result['original_label']}');
        }
      } else {
        _logger.i('Người dùng hủy chọn ảnh từ thư viện');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi chọn ảnh từ thư viện: $e', stackTrace: stackTrace);
      _showErrorSnackBar('Lỗi khi chọn ảnh: $e');
    }
  }

  Future<void> _pickImageFromDrive() async {
    _logger.i('Bắt đầu chọn ảnh từ Google Drive...');
    try {
      final googleSignIn = GoogleSignIn(
        scopes: ['https://www.googleapis.com/auth/drive.readonly'],
      );
      final GoogleSignInAccount? account = await googleSignIn.signIn();
      if (account == null) {
        _logger.w('Người dùng hủy đăng nhập Google');
        _showErrorSnackBar('Đã hủy đăng nhập Google');
        return;
      }

      final authHeaders = await account.authHeaders;
      final accessToken = authHeaders['Authorization']?.split(' ')[1];
      if (accessToken == null) {
        _logger.e('Không thể lấy access token từ Google Sign-In');
        _showErrorSnackBar('Không thể lấy access token');
        return;
      }

      _logger.i('Đang lấy danh sách file từ Google Drive...');
      final response = await http.get(
        Uri.parse(
          'https://www.googleapis.com/drive/v3/files?q=mimeType%3D%27image%2Fjpeg%27%20or%20mimeType%3D%27image%2Fpng%27&fields=files(id,name,webContentLink,thumbnailLink)&spaces=drive',
        ),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files = data['files'] as List<dynamic>;
        if (files.isEmpty) {
          _logger.w('Không tìm thấy file ảnh trên Google Drive');
          _showErrorSnackBar('Không tìm thấy ảnh trên Google Drive');
          return;
        }
        _logger.i('Đã tìm thấy ${files.length} file ảnh trên Google Drive');

        if (mounted) {
          final selectedFile = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Chọn ảnh từ Google Drive'),
              content: SingleChildScrollView(
                child: Column(
                  children: files.map((file) {
                    return ListTile(
                      title: Text(file['name']),
                      onTap: () => Navigator.pop(context, file),
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Hủy'),
                ),
              ],
            ),
          );

          if (selectedFile != null) {
            _logger.i('Đã chọn file từ Google Drive: ${selectedFile['name']}');
            await _setFilePermissions(selectedFile['id'], accessToken);
            final imageBytes = await _downloadImageFromUrl(selectedFile['webContentLink']);
            if (imageBytes != null) {
              setState(() {
                _imagePath = selectedFile['webContentLink'];
                _image = null;
                _aiResult = null;
              });
              _logger.i('Đã tải dữ liệu ảnh từ Google Drive');
              final result = await _runInference(imageBytes);
              if (mounted && result != null) {
                setState(() {
                  _aiResult = result;
                  _nameController.text = result['label'];
                  _logger.i('Cập nhật _nameController.text: "${_nameController.text}"');
                });
                _logger.i('Kết quả nhận diện AI từ ảnh Google Drive: ${result['label']} (${result['confidence'].toStringAsFixed(1)}%), Nhãn gốc: ${result['original_label']}');
              }
            }
          } else {
            _logger.i('Người dùng hủy chọn ảnh từ Google Drive');
          }
        }
      } else {
        _logger.e('Lỗi khi lấy danh sách file từ Google Drive: HTTP ${response.statusCode}');
        _showErrorSnackBar('Lỗi khi lấy danh sách file từ Google Drive: HTTP ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi chọn ảnh từ Google Drive: $e', stackTrace: stackTrace);
      _showErrorSnackBar('Lỗi khi chọn ảnh từ Google Drive: $e');
    }
  }

  Future<void> _setFilePermissions(String fileId, String accessToken) async {
    _logger.i('Đang thiết lập quyền cho file Google Drive: $fileId');
    try {
      final response = await http.post(
        Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId/permissions'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'type': 'anyone', 'role': 'reader'}),
      );
      if (response.statusCode != 200) {
        _logger.w('Lỗi khi thiết lập quyền cho file Google Drive: HTTP ${response.statusCode}');
      } else {
        _logger.i('Đã thiết lập quyền cho file Google Drive: $fileId');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi thiết lập quyền cho file Google Drive: $e', stackTrace: stackTrace);
    }
  }

  Future<void> _takePhoto() async {
    _logger.i('Bắt đầu chụp ảnh...');
    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (pickedFile != null) {
        final imageBytes = await File(pickedFile.path).readAsBytes();
        setState(() {
          _image = File(pickedFile.path);
          _imagePath = pickedFile.path;
          _aiResult = null;
        });
        _logger.i('Đã chụp ảnh: ${pickedFile.path}');
        final result = await _runInference(imageBytes);
        if (mounted && result != null) {
          setState(() {
            _aiResult = result;
            _nameController.text = result['label'];
            _logger.i('Cập nhật _nameController.text: "${_nameController.text}"');
          });
          _logger.i('Kết quả nhận diện AI từ ảnh chụp: ${result['label']} (${result['confidence'].toStringAsFixed(1)}%), Nhãn gốc: ${result['original_label']}');
        }
      } else {
        _logger.i('Người dùng hủy chụp ảnh');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi chụp ảnh: $e', stackTrace: stackTrace);
      _showErrorSnackBar('Lỗi khi chụp ảnh: $e');
    }
  }

  Future<String?> _uploadToGoogleDrive(String filePath) async {
    if (_driveApi == null) {
      _logger.w('Google Drive chưa được khởi tạo. Sử dụng ảnh cục bộ.');
      _showErrorSnackBar('Google Drive chưa được khởi tạo. Sử dụng ảnh cục bộ.');
      return filePath;
    }

    _logger.i('Bắt đầu tải ảnh lên Google Drive: $filePath');
    try {
      var connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        _logger.e('Không có kết nối mạng. Vui lòng kiểm tra kết nối.');
        throw Exception('Không có kết nối mạng. Vui lòng kiểm tra kết nối.');
      }

      final file = File(filePath);
      if (!await file.exists()) {
        _logger.e('Tệp không tồn tại tại đường dẫn: $filePath');
        throw Exception('Tệp không tồn tại tại đường dẫn: $filePath');
      }

      var driveFile = drive.File();
      driveFile.name = 'food_${DateTime.now().millisecondsSinceEpoch}.jpg';
      driveFile.parents = ['appDataFolder'];

      var media = drive.Media(file.openRead(), await file.length());
      final uploadedFile = await _driveApi!.files.create(driveFile, uploadMedia: media);

      final fileId = uploadedFile.id;
      if (fileId == null) {
        _logger.e('Không thể lấy ID của file đã tải lên');
        throw Exception('Không thể lấy ID của file đã tải lên');
      }

      await _driveApi!.permissions.create(
        drive.Permission()..type = 'anyone'..role = 'reader',
        fileId,
      );

      final url = 'https://drive.google.com/uc?export=download&id=$fileId';
      _logger.i('Đã tải lên Google Drive thành công: $url');
      return url;
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải lên Google Drive: $e', stackTrace: stackTrace);
      _showErrorSnackBar('Lỗi khi tải lên Google Drive: $e');
      return null;
    }
  }

  Future<void> _saveFood() async {
    if (!mounted || _isSaving || _formKey.currentState == null || !_formKey.currentState!.validate()) {
      _logger.w('Vui lòng kiểm tra lại thông tin nhập vào');
      if (mounted) _showErrorSnackBar('Vui lòng kiểm tra lại thông tin nhập vào.');
      return;
    }

    if (_selectedAreaId == null || _selectedCategoryId == null || _unitId == null) {
      _logger.w('Vui lòng chọn khu vực, danh mục và đơn vị');
      if (mounted) _showErrorSnackBar('Vui lòng chọn khu vực, danh mục và đơn vị.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      _logger.i('Bắt đầu lưu thực phẩm: ${_nameController.text.trim()}');
      String? imageUrl;
      if (_image != null) {
        imageUrl = await _uploadToGoogleDrive(_imagePath!);
        if (imageUrl == null) {
          _logger.e('Không thể tải ảnh lên Google Drive');
          throw Exception('Không thể tải ảnh lên Google Drive');
        }
      } else {
        imageUrl = _imagePath;
      }

      final foodResponse = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_food'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _nameController.text.trim(),
          'categoryId': _selectedCategoryId,
          'userId': widget.uid,
          'imageUrl': imageUrl,
        }),
      );

      final foodData = jsonDecode(foodResponse.body);
      if (foodResponse.statusCode != 200) {
        _logger.e('Lỗi khi thêm thực phẩm: ${foodData['error'] ?? 'Không xác định'}');
        throw Exception(foodData['error'] ?? 'Lỗi khi thêm thực phẩm');
      }

      final foodId = foodData['foodId'] as String?;
      if (foodId == null) {
        _logger.e('Không nhận được foodId');
        throw Exception('Không nhận được foodId');
      }

      final expiryDateString = DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'+07:00'").format(_expiryDate);

      final storageResponse = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_storage_log'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'foodId': foodId,
          'quantity': double.parse(_quantityController.text.trim()),
          'unitId': _unitId,
          'areaId': _selectedAreaId,
          'expiryDate': expiryDateString,
          'userId': widget.uid,
          'fridgeId': widget.fridgeId,
        }),
      );

      final storageData = jsonDecode(storageResponse.body);
      if (storageResponse.statusCode != 200) {
        _logger.e('Lỗi khi thêm thông tin lưu trữ: ${storageData['error'] ?? 'Không xác định'}');
        throw Exception(storageData['error'] ?? 'Lỗi khi thêm thông tin lưu trữ');
      }

      _logger.i('Đã thêm thực phẩm và thông tin lưu trữ thành công: foodId=$foodId');
      if (mounted) {
        _showSuccessSnackBar('Đã thêm thực phẩm thành công!');
        Navigator.pop(context, true);
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi lưu thực phẩm: $e', stackTrace: stackTrace);
      if (mounted) {
        _showErrorSnackBar('Lỗi khi lưu thực phẩm: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showImageSourceDialog() {
    _logger.i('Mở dialog chọn nguồn ảnh');
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: currentSurfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 5,
              decoration: BoxDecoration(
                color: currentTextSecondaryColor.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Chọn nguồn ảnh',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              alignment: WrapAlignment.center,
              children: [
                _buildModernImageSourceButton(
                  icon: Icons.photo_library_rounded,
                  label: 'Thư viện',
                  color: primaryColor,
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage();
                  },
                ),
                _buildModernImageSourceButton(
                  icon: Icons.cloud_rounded,
                  label: 'Google Drive',
                  color: accentColor,
                  onTap: () {
                    Navigator.pop(context);
                    _pickImageFromDrive();
                  },
                ),
                _buildModernImageSourceButton(
                  icon: Icons.camera_alt_rounded,
                  label: 'Chụp ảnh',
                  color: primaryColor,
                  onTap: () {
                    Navigator.pop(context);
                    _takePhoto();
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildModernImageSourceButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Container(
      width: 100,
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: currentTextPrimaryColor,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddUnitDialog() async {
    _logger.i('Mở dialog thêm đơn vị mới');
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.add_circle_outline, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm đơn vị mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên đơn vị',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _logger.i('Người dùng hủy thêm đơn vị');
              Navigator.pop(context);
            },
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _logger.w('Vui lòng nhập tên đơn vị');
                _showErrorSnackBar('Vui lòng nhập tên đơn vị');
                return;
              }
              try {
                _logger.i('Đang gửi yêu cầu thêm đơn vị: $name');
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_unit'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'name': name}),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200 && data['success']) {
                  await _fetchUnits();
                  setState(() {
                    _unitId = data['unitId'];
                  });
                  _logger.i('Đã thêm đơn vị thành công: $name');
                  _showErrorSnackBar('Đã thêm đơn vị thành công!');
                  Navigator.pop(context);
                } else {
                  _logger.e('Lỗi khi thêm đơn vị: ${data['error']}');
                  _showErrorSnackBar('Lỗi khi thêm đơn vị: ${data['error']}');
                }
              } catch (e, stackTrace) {
                _logger.e('Lỗi khi thêm đơn vị: $e', stackTrace: stackTrace);
                _showErrorSnackBar('Lỗi khi thêm đơn vị: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddCategoryDialog() async {
    _logger.i('Mở dialog thêm danh mục mới');
    final controller = TextEditingController();
    if (!mounted) {
      _logger.w('Widget đã bị hủy trước khi mở dialog thêm danh mục');
      return;
    }
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.category_outlined, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm danh mục mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên danh mục',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _logger.i('Người dùng hủy thêm danh mục');
              Navigator.pop(context);
            },
            child: Text(
              'Hủy',
              style: TextStyle(color: currentTextSecondaryColor),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _logger.w('Tên danh mục không được để trống');
                _showErrorSnackBar('Vui lòng nhập tên danh mục');
                return;
              }
              try {
                _logger.i('Đang gửi yêu cầu thêm danh mục: $name');
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_food_category'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'name': name, 'urlImage': ''}),
                ).timeout(const Duration(seconds: 10), onTimeout: () {
                  _logger.e('Yêu cầu API hết thời gian');
                  throw Exception('Yêu cầu API hết thời gian');
                });
                _logger.i('Phản hồi từ API: statusCode=${response.statusCode}, body=${response.body}');
                if (response.statusCode == 200) {
                  final data = jsonDecode(response.body);
                  if (data['success'] == true) {
                    if (!data.containsKey('categoryId') || data['categoryId'] == null) {
                      _logger.e('API không trả về categoryId hợp lệ: $data');
                      _showErrorSnackBar('Lỗi: API không trả về categoryId hợp lệ');
                      return;
                    }
                    _logger.i('API trả về thành công, categoryId: ${data['categoryId']}');
                    await _fetchFoodCategories();
                    if (mounted) {
                      setState(() {
                        _selectedCategoryId = data['categoryId'];
                      });
                      _logger.i('Đã thêm danh mục thành công: $name, cập nhật _selectedCategoryId: ${_selectedCategoryId}');
                      _showErrorSnackBar('Đã thêm danh mục thành công!');
                      Navigator.pop(context);
                    } else {
                      _logger.w('Widget đã bị hủy trước khi cập nhật trạng thái danh mục');
                    }
                  } else {
                    _logger.e('API trả về thất bại: ${data['error'] ?? 'Không có thông tin lỗi'}');
                    _showErrorSnackBar('Lỗi khi thêm danh mục: ${data['error'] ?? 'Không xác định'}');
                  }
                } else {
                  _logger.e('Yêu cầu API thất bại, mã trạng thái: ${response.statusCode}, body: ${response.body}');
                  _showErrorSnackBar('Lỗi khi thêm danh mục: Mã trạng thái ${response.statusCode}');
                }
              } catch (e, stackTrace) {
                _logger.e('Lỗi khi thêm danh mục: $e', stackTrace: stackTrace);
                _showErrorSnackBar('Lỗi khi thêm danh mục: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    _logger.i('Hiển thị SnackBar lỗi: $message');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
          ],
        ),
        backgroundColor: errorColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    _logger.i('Hiển thị SnackBar thành công: $message');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
          ],
        ),
        backgroundColor: successColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: currentBackgroundColor,
      body: _isLoading
          ? Container(
        color: currentBackgroundColor,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: currentSurfaceColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: LoadingAnimationWidget.threeArchedCircle(
                  color: primaryColor,
                  size: 60,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Đang tải dữ liệu...',
                style: TextStyle(
                  color: currentTextPrimaryColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      )
          : SafeArea(
        child: Column(
          children: [
            SlideTransition(
              position: _headerSlideAnimation,
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, accentColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: -40,
                      right: -40,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -40,
                      left: -20,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: IconButton(
                            icon: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                            onPressed: () => Navigator.pop(context),
                            padding: const EdgeInsets.all(8),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Thêm Thực Phẩm',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 48), // Placeholder for alignment
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildImageSection(),
                        const SizedBox(height: 20),
                        _buildFormSection(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    return Container(
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 200,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              color: currentBackgroundColor.withOpacity(0.1),
            ),
            child: _image != null
                ? Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Image.file(
                    _image!,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        Center(child: Icon(Icons.error, color: errorColor, size: 40)),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      onPressed: () {
                        setState(() {
                          _image = null;
                          _imagePath = null;
                          _aiResult = null;
                          _nameController.clear();
                        });
                      },
                    ),
                  ),
                ),
              ],
            )
                : _imagePath != null
                ? Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Image.network(
                    _imagePath!,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                              loadingProgress.expectedTotalBytes!
                              : null,
                          color: primaryColor,
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) =>
                        Center(child: Icon(Icons.error, color: errorColor, size: 40)),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      onPressed: () {
                        setState(() {
                          _image = null;
                          _imagePath = null;
                          _aiResult = null;
                          _nameController.clear();
                        });
                      },
                    ),
                  ),
                ),
              ],
            )
                : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [primaryColor.withOpacity(0.1), accentColor.withOpacity(0.1)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.add_photo_alternate_rounded,
                    size: 40,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Thêm ảnh thực phẩm',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: currentTextPrimaryColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'AI sẽ tự động nhận diện thực phẩm',
                  style: TextStyle(
                    fontSize: 14,
                    color: currentTextSecondaryColor,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (_image == null && _imagePath == null)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryColor, accentColor],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: TextButton.icon(
                      onPressed: _isLoading ? null : _showImageSourceDialog,
                      icon: const Icon(Icons.add_a_photo_rounded, color: Colors.white),
                      label: const Text(
                        'Chọn ảnh',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                if (_aiResult != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(top: 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [successColor.withOpacity(0.1), successColor.withOpacity(0.05)],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: successColor.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: successColor.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.smart_toy_rounded, color: successColor, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'AI nhận diện',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: successColor,
                                ),
                              ),
                              Text(
                                '${_aiResult!['label']} (${_aiResult!['confidence'].toStringAsFixed(1)}%)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: currentTextPrimaryColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormSection() {
    return Container(
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: _storageAreas.isEmpty || _units.isEmpty || _foodCategories.isEmpty
          ? Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.warning_rounded, color: warningColor, size: 40),
          const SizedBox(height: 16),
          Text(
            _storageAreas.isEmpty
                ? 'Không có khu vực lưu trữ. Vui lòng thêm khu vực lưu trữ trong tủ lạnh.'
                : _units.isEmpty
                ? 'Không có đơn vị. Vui lòng thêm đơn vị.'
                : 'Không có danh mục thực phẩm. Vui lòng thêm danh mục.',
            style: TextStyle(
              fontSize: 16,
              color: currentTextPrimaryColor,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              if (_storageAreas.isEmpty) {
                _showAddAreaDialog();
              } else if (_units.isEmpty) {
                _showAddUnitDialog();
              } else {
                _showAddCategoryDialog();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: Text(
              _storageAreas.isEmpty
                  ? 'Thêm khu vực lưu trữ'
                  : _units.isEmpty
                  ? 'Thêm đơn vị'
                  : 'Thêm danh mục thực phẩm',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      )
          : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Thông tin thực phẩm',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 20),
          _buildModernTextField(
            label: 'Tên thực phẩm',
            hint: 'Nhập tên thực phẩm',
            icon: Icons.fastfood_rounded,
            controller: _nameController,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Vui lòng nhập tên thực phẩm';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _buildModernTextField(
                  label: 'Số lượng',
                  hint: 'Nhập số lượng',
                  icon: Icons.numbers_rounded,
                  controller: _quantityController,
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Vui lòng nhập số lượng';
                    }
                    try {
                      final number = double.parse(value.trim());
                      if (number <= 0) {
                        return 'Số lượng phải lớn hơn 0';
                      }
                    } catch (e) {
                      return 'Vui lòng nhập số hợp lệ';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 3,
                child: _buildModernDropdown<String>(
                  label: 'Đơn vị',
                  icon: Icons.scale_rounded,
                  value: _unitId,
                  items: [
                    ..._units.map((unit) => DropdownMenuItem<String>(
                      value: unit['id'],
                      child: Text(
                        unit['name'],
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    )),
                    DropdownMenuItem<String>(
                      value: 'add_new',
                      child: Row(
                        children: [
                          Icon(Icons.add_circle_outline, color: primaryColor, size: 20),
                          const SizedBox(width: 8),
                          const Text('Thêm đơn vị mới'),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == 'add_new') {
                      _showAddUnitDialog();
                    } else {
                      setState(() {
                        _unitId = value;
                      });
                      _logger.i('Đã chọn đơn vị: $value');
                    }
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty || value == 'add_new') {
                      return 'Vui lòng chọn đơn vị';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildModernDropdown<String>(
            label: 'Danh mục',
            icon: Icons.category_rounded,
            value: _selectedCategoryId,
            items: [
              ..._foodCategories.map((category) => DropdownMenuItem<String>(
                value: category['id'],
                child: Text(
                  category['name'],
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              )),
              DropdownMenuItem<String>(
                value: 'add_new',
                child: Row(
                  children: [
                    Icon(Icons.add_circle_outline, color: primaryColor, size: 20),
                    const SizedBox(width: 8),
                    const Text('Thêm danh mục mới'),
                  ],
                ),
              ),
            ],
            onChanged: (value) {
              if (value == 'add_new') {
                _showAddCategoryDialog();
              } else {
                setState(() {
                  _selectedCategoryId = value;
                });
                _logger.i('Đã chọn danh mục: $value');
              }
            },
            validator: (value) {
              if (value == null || value.isEmpty || value == 'add_new') {
                return 'Vui lòng chọn danh mục';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          _buildDateSelector(),
          const SizedBox(height: 16),
          _buildModernDropdown<String>(
            label: 'Khu vực lưu trữ',
            icon: Icons.kitchen_rounded,
            value: _selectedAreaId,
            items: _storageAreas.map((area) => DropdownMenuItem<String>(
              value: area['id'],
              child: Text(
                area['name'],
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            )).toList(),
            onChanged: (value) {
              setState(() {
                _selectedAreaId = value;
              });
              _logger.i('Đã chọn khu vực lưu trữ: $value');
            },
            validator: (value) {
              if (value == null || value.isEmpty) {
                return 'Vui lòng chọn khu vực lưu trữ';
              }
              return null;
            },
          ),
          _buildSaveButton(),
        ],
      ),
    );
  }
  Future<void> _showAddAreaDialog() async {
    _logger.i('Mở dialog thêm khu vực lưu trữ mới');
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.add_location_alt_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm khu vực mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên khu vực (VD: Ngăn đông, Ngăn mát)',
            hintStyle: TextStyle(color: currentTextSecondaryColor),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _logger.i('Người dùng hủy thêm khu vực lưu trữ');
              Navigator.of(context).pop();
            },
            child: Text(
              'Hủy',
              style: TextStyle(color: currentTextSecondaryColor),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _logger.w('Vui lòng nhập tên khu vực lưu trữ');
                _showErrorSnackBar('Vui lòng nhập tên khu vực lưu trữ');
                return;
              }
              try {
                _logger.i('Đang thêm khu vực lưu trữ: $name');
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_area'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'name': name,
                    'fridgeId': widget.fridgeId,
                    'userId': widget.uid,
                  }),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200) {
                  _logger.i('Đã thêm khu vực lưu trữ thành công: $name');
                  await _fetchStorageAreas();
                  _showSuccessSnackBar('Đã thêm khu vực lưu trữ thành công!');
                  Navigator.of(context).pop();
                } else {
                  _logger.e('Lỗi khi thêm khu vực lưu trữ: ${data['error'] ?? 'Không xác định'}');
                  _showErrorSnackBar('Lỗi khi thêm khu vực lưu trữ: ${data['error'] ?? 'Không xác định'}');
                }
              } catch (e, stackTrace) {
                _logger.e('Lỗi khi thêm khu vực lưu trữ: $e', stackTrace: stackTrace);
                _showErrorSnackBar('Lỗi khi thêm khu vực lưu trữ: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text(
              'Lưu',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateSelector() {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Text(
        'Ngày hết hạn',
        style: TextStyle(        fontSize: 16,
          fontWeight: FontWeight.w600,
          color: currentTextPrimaryColor,
        ),
        ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _selectExpiryDate,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: currentTextSecondaryColor.withOpacity(0.3)),
                borderRadius: BorderRadius.circular(12),
                color: currentSurfaceColor,
              ),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_rounded, color: primaryColor, size: 20),
                  const SizedBox(width: 12),
                  Text(
                    DateFormat('dd/MM/yyyy').format(_expiryDate),
                    style: TextStyle(
                      fontSize: 14,
                      color: currentTextPrimaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.arrow_drop_down, color: currentTextSecondaryColor),
                ],
              ),
            ),
          ),
        ],
    );
  }

  Future<void> _selectExpiryDate() async {
    _logger.i('Mở dialog chọn ngày hết hạn');
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: ColorScheme.light(
              primary: primaryColor,
              onPrimary: Colors.white,
              surface: currentSurfaceColor,
              onSurface: currentTextPrimaryColor,
            ),
            dialogBackgroundColor: currentSurfaceColor,
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _expiryDate) {
      setState(() {
        _expiryDate = picked;
      });
      _logger.i('Đã chọn ngày hết hạn: ${DateFormat('dd/MM/yyyy').format(picked)}');
    } else {
      _logger.i('Người dùng hủy chọn ngày hết hạn');
    }
  }

  Widget _buildModernTextField({
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController controller,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: validator,
          style: TextStyle(color: currentTextPrimaryColor),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: currentTextSecondaryColor),
            prefixIcon: Icon(icon, color: primaryColor, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: currentTextSecondaryColor.withOpacity(0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: currentTextSecondaryColor.withOpacity(0.3)),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: errorColor),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: errorColor, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModernDropdown<T>({
    required String label,
    required IconData icon,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required void Function(T?) onChanged,
    String? Function(T?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField2<T>(
          value: items.isEmpty ? null : value, // Đặt value thành null nếu items rỗng
          items: items.isEmpty
              ? [
            DropdownMenuItem<T>(
              value: null,
              child: Text(
                'Không có dữ liệu',
                style: TextStyle(color: currentTextSecondaryColor),
              ),
            ),
          ]
              : items.map((item) {
            return DropdownMenuItem<T>(
              value: item.value,
              child: Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: item.child, // Sử dụng trực tiếp item.child, không cần kiểm tra Text
                ),
              ),
            );
          }).toList(),
          onChanged: items.isEmpty ? null : onChanged, // Vô hiệu hóa onChanged nếu rỗng
          validator: validator,
          isExpanded: true,
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: primaryColor, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: currentTextSecondaryColor.withOpacity(0.3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: currentTextSecondaryColor.withOpacity(0.3)),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: errorColor),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: errorColor, width: 2),
            ),
          ),
          style: TextStyle(
            color: currentTextPrimaryColor,
            fontSize: 14,
          ),
          dropdownStyleData: DropdownStyleData(
            maxHeight: 300,
            width: 280,
            decoration: BoxDecoration(
              color: currentSurfaceColor,
              borderRadius: BorderRadius.circular(12),
            ),
            offset: const Offset(0, -8),
          ),
          menuItemStyleData: MenuItemStyleData(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            height: 48,
          ),
          iconStyleData: IconStyleData(
            icon: Icon(Icons.arrow_drop_down, color: currentTextSecondaryColor),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 24, bottom: 16),
      child: ElevatedButton(
        onPressed: _isSaving || _isLoading ? null : _saveFood,
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
          shadowColor: primaryColor.withOpacity(0.3),
        ),
        child: _isSaving
            ? LoadingAnimationWidget.threeArchedCircle(
          color: Colors.white,
          size: 24,
        )
            : const Text(
          'Lưu thực phẩm',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}