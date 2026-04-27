import 'package:flutter/material.dart';

class MotorTile extends StatelessWidget {
  final String title;
  final String status;
  final Color statusColor;
  final VoidCallback onStart;
  final VoidCallback onReverse;
  final VoidCallback onStop;
  final bool isEnabled;

  const MotorTile({
    super.key,
    required this.title,
    required this.status,
    required this.statusColor,
    required this.onStart,
    required this.onReverse,
    required this.onStop,
    this.isEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    bool isAtUpperLimit = status.contains("UP") || status.contains("FRONT");
    bool isAtLowerLimit = status.contains("DOWN") || status.contains("BACK");

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withOpacity(0.3), width: 1),
        boxShadow: [
          BoxShadow(
            color: statusColor.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildActionButton(
                label: "START",
                icon: Icons.play_arrow,
                color: Colors.green,
                onPressed: (!isEnabled || isAtUpperLimit) ? null : onStart,
              ),
              const SizedBox(width: 12),
              _buildActionButton(
                label: "REVERSE",
                icon: Icons.swap_horiz,
                color: Colors.orange,
                onPressed: (!isEnabled || isAtLowerLimit) ? null : onReverse,
              ),
              const SizedBox(width: 12),
              _buildActionButton(
                label: "STOP",
                icon: Icons.stop,
                color: Colors.red,
                onPressed: !isEnabled ? null : onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1.0,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color.withOpacity(0.2), color.withOpacity(0.05)],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
