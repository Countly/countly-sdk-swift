Pod::Spec.new do |s|
  s.name = 'CountlySwift'
  s.version = '26.8.0'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.summary  = 'Countly is an innovative, real-time, open source mobile analytics platform.'
  s.homepage = 'https://github.com/Countly/countly-sdk-swift'
  s.author = {'Countly' => 'hello@count.ly'}
  s.source = { :git => 'https://github.com/Countly/countly-sdk-swift.git', :tag => s.version.to_s }

  s.swift_version = '5.9'
  s.default_subspecs = 'Core'

  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.14'
  s.watchos.deployment_target = '4.0'
  s.tvos.deployment_target = '12.0'
  s.visionos.deployment_target = '1.0'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/Countly/**/*.swift'
    core.ios.frameworks = ['Foundation', 'UIKit', 'UserNotifications', 'CoreLocation', 'WebKit', 'CoreTelephony']
    core.tvos.frameworks = ['Foundation', 'UIKit', 'CoreLocation']
    core.watchos.frameworks = ['Foundation', 'WatchKit', 'CoreLocation']
    core.osx.frameworks = ['Foundation', 'AppKit', 'IOKit', 'UserNotifications', 'CoreLocation']
    core.visionos.frameworks = ['Foundation', 'UIKit', 'UserNotifications', 'CoreLocation', 'WebKit']
  end

  # The notification service extension links this on its own, without the core.
  s.subspec 'NotificationService' do |ns|
    ns.source_files = 'Sources/CountlyNotificationService/**/*.swift'
    ns.ios.deployment_target = '12.0'
    ns.visionos.deployment_target = '1.0'
    ns.ios.frameworks = ['Foundation', 'UserNotifications']
    ns.visionos.frameworks = ['Foundation', 'UserNotifications']
  end
end
