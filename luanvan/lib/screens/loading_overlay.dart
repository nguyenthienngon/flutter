import 'package:flutter/material.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';

class LoadingOverlay {
  static Widget build({required Color color, double size = 100}) {
    return Center(
      child: LoadingAnimationWidget.threeArchedCircle(
        color: color,
        size: size,
      ),
    );
  }
}