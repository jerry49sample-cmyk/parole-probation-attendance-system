import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:last/core/theme/app_colors.dart';
import 'package:last/features/auth/models/user_role.dart';
import 'package:responsive_framework/responsive_framework.dart';

class ShellTab {
  const ShellTab({
    required this.label,
    required this.icon,
    required this.route,
  });

  final String label;
  final IconData icon;
  final String route;
}

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.tabs,
    required this.roleColor,
    this.sidebarRoutes,
  });

  final Widget child;
  final List<ShellTab> tabs;
  final Color roleColor;
  final List<ShellTab>? sidebarRoutes;

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    for (var i = 0; i < tabs.length; i++) {
      if (location.startsWith(tabs[i].route)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = ResponsiveBreakpoints.of(context).largerThan(TABLET);
    final index = _currentIndex(context);

    if (isDesktop) {
      final items = sidebarRoutes ?? tabs;
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: true,
              minExtendedWidth: 200,
              backgroundColor: Colors.white,
              selectedIndex: index.clamp(0, items.length - 1),
              onDestinationSelected: (i) => context.go(items[i].route),
              labelType: NavigationRailLabelType.none,
              selectedIconTheme: IconThemeData(color: roleColor),
              selectedLabelTextStyle: TextStyle(
                color: roleColor,
                fontWeight: FontWeight.w600,
              ),
              destinations: items
                  .map(
                    (t) => NavigationRailDestination(
                      icon: Icon(t.icon),
                      label: Text(t.label),
                    ),
                  )
                  .toList(),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }

    return Scaffold(
      body: child,
      bottomNavigationBar: Material(
        color: Colors.white,
        elevation: 8,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      right: i == tabs.length - 1 ? 0 : 8,
                    ),
                    child: Semantics(
                      button: true,
                      selected: index == i,
                      label: tabs[i].label,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => context.go(tabs[i].route),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          constraints: const BoxConstraints(minWidth: 82),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: index == i
                                ? roleColor.withValues(alpha: 0.09)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                tabs[i].icon,
                                size: 20,
                                color: index == i
                                    ? roleColor
                                    : AppColors.textMuted,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                tabs[i].label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: index == i
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: index == i
                                      ? roleColor
                                      : AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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

List<ShellTab> officerTabs(String base) => [
  ShellTab(
    label: 'Dashboard',
    icon: Icons.dashboard_outlined,
    route: '$base/dashboard',
  ),
  ShellTab(
    label: 'Activities',
    icon: Icons.event_note_outlined,
    route: '$base/activities',
  ),
  ShellTab(
    label: 'GPS Trackers',
    icon: Icons.gps_fixed,
    route: '$base/trackers',
  ),
  ShellTab(
    label: 'User Management',
    icon: Icons.people_outline,
    route: '$base/users',
  ),
  ShellTab(
    label: 'Reports',
    icon: Icons.bar_chart_outlined,
    route: '$base/reports',
  ),
  ShellTab(
    label: 'Notifications',
    icon: Icons.notifications_outlined,
    route: '$base/notifications',
  ),
  ShellTab(
    label: 'Officer Profile',
    icon: Icons.person_outline,
    route: '$base/profile',
  ),
];

List<ShellTab> paroleeTabs(String base) => [
  ShellTab(
    label: 'Dashboard',
    icon: Icons.home_outlined,
    route: '$base/dashboard',
  ),
  ShellTab(
    label: 'My Activities',
    icon: Icons.event_available_outlined,
    route: '$base/activities',
  ),
  ShellTab(
    label: 'Check-in QR',
    icon: Icons.fact_check_outlined,
    route: '$base/check-in',
  ),
  ShellTab(label: 'History', icon: Icons.history, route: '$base/history'),
  ShellTab(
    label: 'Notifications',
    icon: Icons.notifications_outlined,
    route: '$base/notifications',
  ),
  ShellTab(
    label: 'My Profile',
    icon: Icons.person_outline,
    route: '$base/profile',
  ),
];

Color roleColor(UserRole role) {
  switch (role) {
    case UserRole.officer:
      return AppColors.officer;
    case UserRole.parolee:
      return AppColors.parolee;
  }
}
