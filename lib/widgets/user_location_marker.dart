import 'package:flutter/material.dart';

import 'dart:math' as math;

import 'triangle_clipper.dart';

class UserLocationMarker extends StatelessWidget {
  final double heading; // в градусах

  const UserLocationMarker({super.key, required this.heading});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: (heading * (math.pi / 180)),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blue.withValues(alpha: 0.22),
            ),
          ),
          Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
          Container(
            width: 15,
            height: 15,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF1E88E5),
            ),
          ),
          Positioned(
            top: 2,
            child: ClipPath(
              clipper: TriangleClipper(),
              child: Container(
                width: 8,
                height: 8,
                color: const Color(0xFF1E88E5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
