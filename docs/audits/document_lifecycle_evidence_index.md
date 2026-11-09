# فهرس أدلة دورة الحياة

الأساس: `d8058755705ef234f9a1995e309265d63ee2cc95`؛ التاريخ 2026-11-09.

هذا **فهرس الملفات التي أمكن حل إحالاتها الصريحة المفردة آلياً في التقرير**، وليس سجل قراءة حرفية لكل أسطر كل ملف. قرئت التطبيقات ومواقع الاستدعاء والمقاطع الاختبارية على دفعات؛ بعض المخرجات الطويلة كانت مبتورة ثم استكملت مقاطع مستهدفة. لا يتوفر عداد مستقل موثوق لجميع الملفات التي فُتحت في الجلسة، لذلك لا نختلق رقماً لقراءة شاملة. الجداول ذات الاختصار `{a,b}` تضيف إحالات أخرى غير محسوبة هنا.

عدد الملفات ذات الإحالات المفردة المحلولة: **113**. جرد check_source البالغ 277 ملف Dart و1150 تصريح اختبار لا يمثل عدد ملفات القراءة أو اختبارات منفذة.

## ملفات الإحالات

- `.github/workflows/verify.yml`
- `android/app/src/main/kotlin/iq/scanid/scan_id/NativeCamera.kt`
- `android/app/src/main/kotlin/iq/scanid/scan_id/NativeLargeJpegScaler.kt`
- `integration_test/ocr_inference_test.dart`
- `lib/application/camera_capture.dart`
- `lib/application/contracts.dart`
- `lib/application/ids.dart`
- `lib/application/image_reader.dart`
- `lib/application/multi_document_segmentation_flag.dart`
- `lib/application/native_documents.dart`
- `lib/application/ocr_model_assets.dart`
- `lib/application/output_service.dart`
- `lib/application/paddle_ocr_engine.dart`
- `lib/application/paddle_ocr_runtime.dart`
- `lib/application/project_service.dart`
- `lib/application/recognition_pipeline.dart`
- `lib/application/recognition_worker.dart`
- `lib/application/retirable_resource.dart`
- `lib/application/smart_recognition.dart`
- `lib/application/smart_recognition_flag.dart`
- `lib/application/stage_budget.dart`
- `lib/domain/acceptance_policy.dart`
- `lib/domain/arrangement.dart`
- `lib/domain/boundary_decision.dart`
- `lib/domain/crop_draft.dart`
- `lib/domain/document_edits.dart`
- `lib/domain/document_kind.dart`
- `lib/domain/export_plan.dart`
- `lib/domain/geometry.dart`
- `lib/domain/image_limits.dart`
- `lib/domain/manual_boundary.dart`
- `lib/domain/manual_classification.dart`
- `lib/domain/manual_quad_selection.dart`
- `lib/domain/ocr_decoding.dart`
- `lib/domain/ocr_evidence.dart`
- `lib/domain/packing.dart`
- `lib/domain/page_layout.dart`
- `lib/domain/physical_aspect.dart`
- `lib/domain/project.dart`
- `lib/domain/quad_assessment.dart`
- `lib/domain/recognition.dart`
- `lib/domain/recognition_classifier.dart`
- `lib/domain/recognition_overrides.dart`
- `lib/domain/recognition_routing.dart`
- `lib/domain/side_pairing.dart`
- `lib/export/document_exporter.dart`
- `lib/imaging/boundary_arbitration.dart`
- `lib/imaging/boundary_proposal_cascade.dart`
- `lib/imaging/db_text_boxes.dart`
- `lib/imaging/docaligner_model.dart`
- `lib/imaging/docquad_model.dart`
- `lib/imaging/document_detector.dart`
- `lib/imaging/full_resolution_manual_crop.dart`
- `lib/imaging/image_header.dart`
- `lib/imaging/large_jpeg_plan.dart`
- `lib/imaging/ocr_tensor.dart`
- `lib/imaging/perspective.dart`
- `lib/imaging/prepare_image.dart`
- `lib/main.dart`
- `lib/persistence/local_asset_repository.dart`
- `lib/persistence/local_image_editor.dart`
- `lib/persistence/local_project_backups.dart`
- `lib/persistence/local_project_repository.dart`
- `lib/persistence/safe_files.dart`
- `lib/presentation/app.dart`
- `lib/presentation/boundary_handle.dart`
- `lib/presentation/boundary_hit_layer.dart`
- `lib/presentation/crop_loupe.dart`
- `lib/presentation/crop_screen.dart`
- `lib/presentation/editor_controller.dart`
- `lib/presentation/export_screen.dart`
- `lib/presentation/intake.dart`
- `lib/presentation/layout_screen.dart`
- `lib/presentation/manual_classification_dialog.dart`
- `lib/presentation/project_screen.dart`
- `lib/presentation/review_screen.dart`
- `lib/reference_annotation/main.dart`
- `pubspec.lock`
- `pubspec.yaml`
- `test/application/boundary_gate_test.dart`
- `test/application/document_classification_path_test.dart`
- `test/application/full_resolution_manual_crop_test.dart`
- `test/application/layout_session_test.dart`
- `test/application/manual_intake_integration_test.dart`
- `test/application/output_service_test.dart`
- `test/application/paddle_ocr_engine_test.dart`
- `test/application/recrop_size_test.dart`
- `test/application/stage1_a4_workflow_test.dart`
- `test/domain/document_size_sources_test.dart`
- `test/domain/manual_boundary_validation_test.dart`
- `test/domain/manual_classification_test.dart`
- `test/domain/side_pairing_test.dart`
- `test/export/document_exporter_test.dart`
- `test/imaging/perspective_test.dart`
- `test/legacy_schemas/v1_1c68dbc/geometry.dart`
- `test/legacy_schemas/v1_1c68dbc/image_limits.dart`
- `test/legacy_schemas/v1_1c68dbc/project.dart`
- `test/legacy_schemas/v2_cd58739/geometry.dart`
- `test/legacy_schemas/v2_cd58739/image_limits.dart`
- `test/legacy_schemas/v2_cd58739/project.dart`
- `test/legacy_schemas/v3a_478e098/geometry.dart`
- `test/legacy_schemas/v3a_478e098/image_limits.dart`
- `test/legacy_schemas/v3a_478e098/project.dart`
- `test/legacy_schemas/v3b_90de23c/geometry.dart`
- `test/legacy_schemas/v3b_90de23c/image_limits.dart`
- `test/legacy_schemas/v3b_90de23c/project.dart`
- `test/legacy_schemas/v3c_64d146e/document_kind.dart`
- `test/legacy_schemas/v3c_64d146e/geometry.dart`
- `test/legacy_schemas/v3c_64d146e/image_limits.dart`
- `test/legacy_schemas/v3c_64d146e/project.dart`
- `tool/fetch_docaligner_model.py`
- `tool/fetch_ocr_models.py`
- `windows/runner/large_jpeg_scaler.cpp`

## دليل التنفيذ

- `document_lifecycle_python_tests.log`: سجل unittest الأصلي، exit1، 38 حالة وخطأ استيراد PIL واحد.
- `document_lifecycle_static_checks.log`: إعادة تنفيذ الفحوص الساكنة الأربعة للتحقق من النتيجة؛ لا يعد نجاحها تنفيذ Flutter.
- Flutter/Dart غير متاحين؛ المانع مسجل في قسم19 من التقرير، ولا نجاح analyze/test مدعى.
- لا مرفقات مرجعية ولا مجموعة ground truth خاصة متاحة، ولا تشغيل inference أو طباعة فعلية.
