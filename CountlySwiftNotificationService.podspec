#
# Local-only podspec so the notification service extension can be built and tested
# on the CocoaPods path.
#
# The extension is a separate module, `CountlyNotificationService`, which the README
# tells hosts to import. CocoaPods treats `module_name` as a root specification
# attribute, so a subspec of `CountlySwift` cannot carry a different module name.
# Delivering both modules therefore needs two pods, not one pod with two subspecs.
#
# Not for release. Raised with the SDK side as a packaging question.
#
Pod::Spec.new do |s|
  s.name = 'CountlySwiftNotificationService'
  s.module_name = 'CountlyNotificationService'
  s.version = '26.8.0'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.summary = 'Notification service extension support for the Countly Swift SDK.'
  s.homepage = 'https://github.com/Countly/countly-sdk-swift'
  s.author = {'Countly' => 'hello@count.ly'}
  s.source = { :git => 'https://github.com/Countly/countly-sdk-swift.git', :tag => s.version.to_s }

  s.swift_version = '5.9'
  s.ios.deployment_target = '15.0'
  s.visionos.deployment_target = '1.0'

  s.source_files = 'Sources/CountlyNotificationService/**/*.swift'
  s.ios.frameworks = ['Foundation', 'UserNotifications']
  s.visionos.frameworks = ['Foundation', 'UserNotifications']
end
