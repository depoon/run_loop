require 'cfpropertylist'

module RunLoop

  # One class interact with the iOS Simulators.
  #
  # @note All command line tools are run in the context of `xcrun`.
  #
  # Throughout this class's documentation, there are references to the
  # _current version of Xcode_.  The current Xcode version is the one returned
  # by `xcrun xcodebuild`.  The current Xcode version can be set using
  # `xcode-select` or overridden using the `DEVELOPER_DIR`.
  #
  # @todo `puts` calls need to be replaced with proper logging
  class SimControl

    # Returns an instance of XCTools.
    # @return [RunLoop::XCTools] The xcode tools instance that is used internally.
    def xctools
      @xctools ||= RunLoop::XCTools.new
    end

    # @!visibility private
    # Are we running Xcode 6 or above?
    #
    # This is a convenience method.
    #
    # @return [Boolean] `true` if the current Xcode version is >= 6.0
    def xcode_version_gte_6?
      xctools.xcode_version_gte_6?
    end

    # @!visibility private
    # Are we running Xcode 5.1 or above?
    #
    # This is a convenience method.
    #
    # @return [Boolean] `true` if the current Xcode version is >= 5.1
    def xcode_version_gte_51?
      xctools.xcode_version_gte_51?
    end

    # Return an instance of PlistBuddy.
    # @return [RunLoop::PlistBuddy] The plist buddy instance that is used internally.
    def pbuddy
      @pbuddy ||= RunLoop::PlistBuddy.new
    end

    # Is the simulator for the current version of Xcode running?
    # @return [Boolean] True if the simulator is running.
    def sim_is_running?
      not sim_pid.nil?
    end

    # If it is running, quit the simulator for the current version of Xcode.
    #
    # @param [Hash] opts Optional controls.
    # @option opts [Float] :post_quit_wait (1.0) How long to sleep after the
    #  simulator has quit.
    #
    # @todo Consider migrating apple script call to xctools.
    def quit_sim(opts={})
      if sim_is_running?
        default_opts = {:post_quit_wait => 1.0 }
        merged_opts = default_opts.merge(opts)
        `echo 'application "#{sim_name}" quit' | xcrun osascript`
        sleep(merged_opts[:post_quit_wait]) if merged_opts[:post_quit_wait]
      end
    end

    # If it is not already running, launch the simulator for the current version
    # of Xcode.
    #
    # @param [Hash] opts Optional controls.
    # @option opts [Float] :post_launch_wait (2.0) How long to sleep after the
    #  simulator has launched.
    # @option opts [Boolean] :hide_after (false) If true, will attempt to Hide
    #  the simulator after it is launched.  This is useful `only when testing
    #  gem features` that require the simulator be launched repeated and you are
    #  tired of your editor losing focus. :)
    #
    # @todo Consider migrating apple script call to xctools.
    def launch_sim(opts={})
      unless sim_is_running?
        default_opts = {:post_launch_wait => 2.0,
                        :hide_after => false}
        merged_opts = default_opts.merge(opts)
        `xcrun open -a "#{sim_app_path}"`
        if merged_opts[:hide_after]
          `xcrun /usr/bin/osascript -e 'tell application "System Events" to keystroke "h" using command down'`
        end
        sleep(merged_opts[:post_launch_wait]) if merged_opts[:post_launch_wait]
      end
    end

    # Relaunch the simulator for the current version of Xcode.  If that
    # simulator is already running, it is quit.
    #
    # @param [Hash] opts Optional controls.
    # @option opts [Float] :post_quit_wait (1.0) How long to sleep after the
    #  simulator has quit.
    # @option opts [Float] :post_launch_wait (2.0) How long to sleep after the
    #  simulator has launched.
    # @option opts [Boolean] :hide_after (false) If true, will attempt to Hide
    #  the simulator after it is launched.  This is useful `only when testing
    #  gem features` that require the simulator be launched repeated and you are
    #  tired of your editor losing focus. :)
    def relaunch_sim(opts={})
      default_opts = {:post_quit_wait => 1.0,
                      :post_launch_wait => 2.0,
                      :hide_after => false}
      merged_opts = default_opts.merge(opts)
      quit_sim(merged_opts)
      launch_sim(merged_opts)
    end

    # Terminates all simulators.
    #
    # @note Sends `kill -9` to all Simulator processes.  Use sparingly or not
    #  at all.
    #
    # SimulatorBridge
    # launchd_sim
    # ScriptAgent
    #
    # There can be only one simulator running at a time.  However, during
    # gem testing, situations can arise where multiple simulators are active.
    def self.terminate_all_sims

      # @todo Throwing SpringBoard crashed UI dialog.
      # Tried the gentle approach first; it did not work.
      # SimControl.new.quit_sim({:post_quit_wait => 0.5})

      processes =
            ['iPhone Simulator.app', 'iOS Simulator.app',

             # Multiple launchd_sim processes have been causing problems.  This
             # is a first pass at investigating what it would mean to kill the
             # launchd_sim process.
             'launchd_sim'

            # RE: Throwing SpringBoard crashed UI dialog
            # These are children of launchd_sim.  I tried quiting them
            # to suppress related UI dialogs about crashing processes.  Killing
            # them can throw 'launchd_sim' UI Dialogs
            #'SimulatorBridge', 'SpringBoard', 'ScriptAgent', 'configd_sim', 'xpcproxy_sim'
            ]

      # @todo Maybe should try to send -TERM first and -KILL if TERM fails.
      # @todo Needs benchmarking.
      processes.each do |process_name|
        descripts = `xcrun ps x -o pid,command | grep "#{process_name}" | grep -v grep`.strip.split("\n")
        descripts.each do |process_desc|
          pid = process_desc.split(' ').first
          Open3.popen3("xcrun kill -9 #{pid} && xcrun wait #{pid}") do  |_, stdout,  stderr, _|
            if ENV['DEBUG_UNIX_CALLS'] == '1'
              out = stdout.read.strip
              err = stderr.read.strip
              next if out.to_s.empty? and err.to_s.empty?
              puts "kill process '#{pid}' => stdout: '#{out}' | stderr: '#{err}'"
            end
          end
        end
      end
    end

    # Resets the simulator content and settings.  It is analogous to touching
    # the menu item _for every simulator_, regardless of SDK.
    #
    #
    # On Xcode 5, it works by deleting the following directories:
    #
    # * ~/Library/Application Support/iPhone Simulator/Library
    # * ~/Library/Application Support/iPhone Simulator/Library/<sdk>[-64]
    #
    # and relaunching the iOS Simulator which will recreate the Library
    # directory and the latest SDK directory.
    #
    # On Xcode 6, it uses the `simctl erase <udid>` command line tool.
    #
    # @param [Hash] opts Optional controls for quitting and launching the simulator.
    # @option opts [Float] :post_quit_wait (1.0) How long to sleep after the
    #  simulator has quit.
    # @option opts [Float] :post_launch_wait (3.0) How long to sleep after the
    #  simulator has launched.  Waits longer than normal because we need the
    #  simulator directories to be repopulated. **NOTE:** This option is ignored
    #  in Xcode 6.
    # @option opts [Boolean] :hide_after (false) If true, will attempt to Hide
    #  the simulator after it is launched.  This is useful `only when testing
    #  gem features` that require the simulator be launched repeated and you are
    #  tired of your editor losing focus. :) **NOTE:** This option is ignored
    #  in Xcode 6.
    def reset_sim_content_and_settings(opts={})
      default_opts = {:post_quit_wait => 1.0,
                      :post_launch_wait => 3.0,
                      :hide_after => false}
      merged_opts = default_opts.merge(opts)

      quit_sim(merged_opts)

      # WARNING - DO NOT TRY TO DELETE Developer/CoreSimulator/Devices!
      # Very bad things will happen.  Unlike Xcode < 6, the re-launching the
      # simulator will _not_ recreate the SDK (aka Devices) directories.
      if xcode_version_gte_6?
        simctl_reset
      else
        sim_lib_path = File.join(sim_app_support_dir, 'Library')
        FileUtils.rm_rf(sim_lib_path)
        existing_sim_sdk_or_device_data_dirs.each do |dir|
          FileUtils.rm_rf(dir)
        end
        launch_sim(merged_opts)

        # This is tricky because we need to wait for the simulator to recreate
        # the directories.  Specifically, we need the Accessibility plist to be
        # exist so subsequent calabash launches will be able to enable
        # accessibility.
        #
        # The directories take ~3.0 - ~5.0 to create.
        counter = 0
        loop do
          break if counter == 80
          dirs = existing_sim_sdk_or_device_data_dirs
          if dirs.count == 0
            sleep(0.2)
          else
            break if dirs.all? { |dir|
              plist = File.expand_path("#{dir}/Library/Preferences/com.apple.Accessibility.plist")
              File.exist?(plist)
            }
            sleep(0.2)
          end
          counter = counter + 1
        end
      end
    end

    # @!visibility private
    # Enables accessibility on all iOS Simulators by adjusting the
    # simulator's Library/Preferences/com.apple.Accessibility.plist contents.
    #
    # A simulator 'exists' if has an Application Support directory. for
    # example, the 6.1, 7.0.3-64, and 7.1 simulators exist if the following
    # directories are present:
    #
    #     ~/Library/Application Support/iPhone Simulator/Library/6.1
    #     ~/Library/Application Support/iPhone Simulator/Library/7.0.3-64
    #     ~/Library/Application Support/iPhone Simulator/Library/7.1
    #
    # A simulator is 'possible' if the SDK is available in the Xcode version.
    #
    # This method merges (uniquely) the possible and existing SDKs.
    #
    # This method also hides the AXInspector.
    #
    # **Q:** _Why do we need to enable for both existing and possible SDKs?_
    # **A:**  Consider what would happen if we were launching against the 7.0.3
    # SDK for the first time.  The 7.0.3 SDK directory does not exist _until the
    # simulator has been launched_.  The upshot is that we need to create the
    # the plist _before_ we try to launch the simulator.
    #
    # @note This method will quit the current simulator.
    #
    # @param [Hash] opts controls the behavior of the method
    # @option opts [Boolean] :verbose controls logging output
    # @return [Boolean] true if enabling accessibility worked on all sdk
    #  directories
    #
    # @todo Should benchmark to see if memo-izing can help speed this up. Or if
    #   we can intuit the SDK and before launching and enable access on only
    #   that SDK.
    #
    # @todo Testing this is _hard_.  ATM, I am using a reset sim content
    #  and settings + RunLoop.run to test.
    def enable_accessibility_on_sims(opts={})
      default_opts = {:verbose => false}
      merged_opts = default_opts.merge(opts)

      existing = existing_sim_sdk_or_device_data_dirs

      if xcode_version_gte_6?
        details = sim_details :udid
        results = existing.map do |dir|
          enable_accessibility_in_sim_data_dir(dir, details, opts)
        end
      else
        possible = XCODE_5_SDKS.map do |sdk|
          File.expand_path("~/Library/Application Support/iPhone Simulator/#{sdk}")
        end

        dirs = (possible + existing).uniq
        results = dirs.map do |dir|
          enable_accessibility_in_sdk_dir(dir, merged_opts)
        end
      end
      results.all?
    end

    # Is the arg a valid Xcode >= 6.0 simulator udid?
    # @param [String] udid the String to check
    # @return [Boolean] Returns true iff the `udid` matches /[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}/
    def sim_udid?(udid)
      udid.length == 36 and udid[XCODE_6_SIM_UDID_REGEX,0] != nil
    end

    def simulators
      unless xcode_version_gte_51?
        raise RuntimeError, 'simctl is only available on Xcode >= 6'
      end

      if xcode_version_gte_6?
        hash = simctl_list :devices
        sims = []
        hash.each_pair do |sdk, list|
          list.each do |details|
            sims << RunLoop::Device.new(details[:name], sdk, details[:udid])
          end
        end
        sims
      else
        raise NotImplementedError, 'the simulators method is not available yet for Xcode 5.1.1'
      end
    end

    private


    # @!visibility private
    # The list of possible SDKs for 5.0 <= Xcode < 6.0
    #
    # @note Used to enable automatically enable accessibility on the simulators.
    #
    # @see #enable_accessibility_on_sims
    XCODE_5_SDKS = ['6.1', '7.0', '7.0.3', '7.0.3-64', '7.1', '7.1-64'].freeze


    # @!visibility private
    # A hash table of the accessibility properties that control whether or not
    # accessibility is enabled and whether the AXInspector is visible.
    #
    # @note Xcode 5 or Xcode 6 SDK < 8.0
    #
    # @see #enable_accessibility_on_sims
    SDK_LT_80_ACCESSIBILITY_PROPERTIES_HASH =
          {
                :access_enabled => {:key => 'AccessibilityEnabled',
                                    :value => 'true',
                                    :type => 'bool'},

                :app_access_enabled => {:key => 'ApplicationAccessibilityEnabled',
                                        :value => 'true',
                                        :type => 'bool'},

                :automation_enabled => {:key => 'AutomationEnabled',
                                        :value => 'true',
                                        :type => 'bool'},

                # Determines if the Accessibility Inspector is showing.
                #
                # It turns out we can set this to 'false' as of Xcode 5.1 and
                # hide the inspector altogether.
                #
                # I don't know what the behavior is on Xcode 5.0*.
                :inspector_showing => {:key => 'AXInspectorEnabled',
                                       :value => 'false',
                                       :type => 'bool'},

                # Controls if the Accessibility Inspector is expanded or not
                # expanded.
                :inspector_full_size => {:key => 'AXInspector.enabled',
                                         :value => 'false',
                                         :type => 'bool'},

                # Controls the frame of the Accessibility Inspector.
                # This is the best we can do because the OS will rewrite the
                # frame if it does not conform to some expected range.
                :inspector_frame => {:key => 'AXInspector.frame',
                                     :value => '{{290, -13}, {276, 166}}',
                                     :type => 'string'},


          }.freeze

    # @!visibility private
    # A hash table of the accessibility properties that control whether or not
    # accessibility is enabled and whether the AXInspector is visible.
    #
    # @note Xcode 6 SDK >= 8.0
    #
    # @see #enable_accessibility_in_sim_data_dir
    SDK_80_ACCESSIBILITY_PROPERTIES_HASH =
          {
                :access_enabled => {:key => 'AccessibilityEnabled',
                                    :value => 'true',
                                    :type => 'bool'},

                :app_access_enabled => {:key => 'ApplicationAccessibilityEnabled',
                                        :value => 1,
                                        :type => 'integer'},

                :automation_enabled => {:key => 'AutomationEnabled',
                                        :value => 1,
                                        :type => 'integer'},

                # Determines if the Accessibility Inspector is showing.
                # Hurray!  We can turn this off in Xcode 6.
                :inspector_showing => {:key => 'AXInspectorEnabled',
                                       :value => 0,
                                       :type => 'integer'},

                # controls if the Accessibility Inspector is expanded or not expanded
                :inspector_full_size => {:key => 'AXInspector.enabled',
                                         :value => 'false',
                                         :type => 'bool'},

                # Controls the frame of the Accessibility Inspector
                #
                # In Xcode 6, positioning this is difficult because the OS
                # rewrites the value if the frame does not conform to an
                # expected range.  This is the best we can do.
                #
                # But see :inspector_showing!  Woot!
                :inspector_frame => {:key => 'AXInspector.frame',
                                     :value => '{{270, 0}, {276, 166}}',
                                     :type => 'string'},

                # new and shiny - looks interesting!
                :automation_disable_faux_collection_cells =>
                      {
                            :key => 'AutomationDisableFauxCollectionCells',
                            :value =>  1,
                            :type => 'integer'
                      }
          }.freeze

    # @!visibility private
    # A regex for finding directories under ~/Library/Developer/CoreSimulator/Devices
    # and parsing the output of `simctl list sessions`.
    XCODE_6_SIM_UDID_REGEX = /[A-F0-9]{8}-([A-F0-9]{4}-){3}[A-F0-9]{12}/.freeze

    # @!visibility private
    # Returns the current Simulator pid.
    #
    # @note Will only search for the current Xcode simulator.
    #
    # @return [String, nil] The pid as a String or nil if no process is found.
    def sim_pid
      `xcrun ps x -o pid,command | grep "#{sim_name}" | grep -v grep`.strip.split(' ').first
    end

    # @!visibility private
    # Returns the current simulator name.
    #
    # @note In Xcode >= 6.0 the simulator name changed.
    #
    # @note Returns with the .app extension because on Xcode < 6.0, multiple
    #  processes can be found with 'iPhone Simulator'; the .app ensures that
    #  other methods find the right pid and application path.
    # @return [String] A String suitable for searching for a pid, quitting, or
    #  launching the current simulator.
    def sim_name
      @sim_name ||= lambda {
        if xcode_version_gte_6?
          'iOS Simulator'
        else
          'iPhone Simulator'
        end
      }.call
    end

    # @!visibility private
    # Returns the path to the current simulator.
    #
    # @note Xcode >= 6.0  the simulator app has a different path.
    #
    # @return [String] The path to the simulator app for the current version of
    #  Xcode.
    def sim_app_path
      @sim_app_path ||= lambda {
        dev_dir = xctools.xcode_developer_dir
        if xcode_version_gte_6?
          "#{dev_dir}/Applications/iOS Simulator.app"
        else
          "#{dev_dir}/Platforms/iPhoneSimulator.platform/Developer/Applications/iPhone Simulator.app"
        end
      }.call
    end

    # @!visibility private
    # The absolute path to the iPhone Simulator Application Support directory.
    # @return [String] absolute path
    def sim_app_support_dir
      if xcode_version_gte_6?
        File.expand_path('~/Library/Developer/CoreSimulator/Devices')
      else
        File.expand_path('~/Library/Application Support/iPhone Simulator')
      end
    end

    # @!visibility private
    # In Xcode 5, this returns a list of absolute paths to the existing
    # simulators SDK directories.
    #
    # In Xcode 6, this returns a list of absolute paths to the existing
    # simulators `<udid>/data` directories.
    #
    # @note This can _never_ be memoized to a variable; its value reflects the
    #  state of the file system at the time it is called.
    #
    # In Xcode 5, a simulator 'exists' if it appears in the Application Support
    # directory.  For example, the 6.1, 7.0.3-64, and 7.1 simulators exist if
    # the following directories are present:
    #
    # ```
    # ~/Library/Application Support/iPhone Simulator/Library/6.1
    # ~/Library/Application Support/iPhone Simulator/Library/7.0.3-64
    # ~/Library/Application Support/iPhone Simulator/Library/7.1
    # ```
    #
    # In Xcode 6, a simulator 'exists' if it appears in the
    # CoreSimulator/Devices directory.  For example:
    #
    # ```
    # ~/Library/Developer/CoreSimulator/Devices/0BF52B67-F8BB-4246-A668-1880237DD17B
    # ~/Library/Developer/CoreSimulator/Devices/2FCF6AFF-8C85-442F-B472-8D489ECBFAA5
    # ~/Library/Developer/CoreSimulator/Devices/578A16BE-C31F-46E5-836E-66A2E77D89D4
    # ```
    #
    # @example Xcode 5 behavior
    #   ~/Library/Application Support/iPhone Simulator/Library/6.1
    #   ~/Library/Application Support/iPhone Simulator/Library/7.0.3-64
    #   ~/Library/Application Support/iPhone Simulator/Library/7.1
    #
    # @example Xcode 6 behavior
    #   ~/Library/Developer/CoreSimulator/Devices/0BF52B67-F8BB-4246-A668-1880237DD17B/data
    #   ~/Library/Developer/CoreSimulator/Devices/2FCF6AFF-8C85-442F-B472-8D489ECBFAA5/data
    #   ~/Library/Developer/CoreSimulator/Devices/578A16BE-C31F-46E5-836E-66A2E77D89D4/data
    #
    # @return[Array<String>] a list of absolute paths to simulator directories
    def existing_sim_sdk_or_device_data_dirs
      base_dir = sim_app_support_dir
      if xcode_version_gte_6?
        regex = XCODE_6_SIM_UDID_REGEX
      else
        regex = /(\d)\.(\d)\.?(\d)?(-64)?/
      end
      dirs = Dir.glob("#{base_dir}/*").select { |path|
        path =~ regex
      }

      if xcode_version_gte_6?
        dirs.map { |elm| File.expand_path(File.join(elm, 'data')) }
      else
        dirs
      end
    end

    # @!visibility private
    # Enables accessibility on the simulator indicated by `app_support_sdk_dir`.
    #
    # @note This will quit the simulator.
    #
    # @note This is for Xcode 5 only.  Will raise an error if called on Xcode 6.
    #
    # @example
    #   path = '~/Library/Application Support/iPhone Simulator/6.1'
    #   enable_accessibility_in_sdk_dir(path)
    #
    # This method also hides the AXInspector.
    #
    # If the Library/Preferences/com.apple.Accessibility.plist does not exist
    # this method will create a Library/Preferences/com.apple.Accessibility.plist
    # that (oddly) the Simulator will _not_ overwrite.
    #
    # @see #enable_accessibility_on_sims for the public API.
    #
    # @param [String] app_support_sdk_dir the directory where the
    #   Library/Preferences/com.apple.Accessibility.plist can be found.
    #
    # @param [Hash] opts controls the behavior of the method
    # @option opts [Boolean] :verbose controls logging output
    # @return [Boolean] if the plist exists and the plist was successfully
    #   updated.
    # @raise [RuntimeError] If called when Xcode 6 is the active Xcode version.
    def enable_accessibility_in_sdk_dir(app_support_sdk_dir, opts={})

      if xcode_version_gte_6?
        raise RuntimeError, 'it is illegal to call this method when Xcode >= 6 is the current Xcode version'
      end

      default_opts = {:verbose => false}
      merged_opts = default_opts.merge(opts)

      quit_sim

      verbose = merged_opts[:verbose]
      sdk = File.basename(app_support_sdk_dir)
      msgs = ["cannot enable accessibility for #{sdk} SDK"]

      plist_path = File.expand_path("#{app_support_sdk_dir}/Library/Preferences/com.apple.Accessibility.plist")

      if File.exist?(plist_path)
        res = SDK_LT_80_ACCESSIBILITY_PROPERTIES_HASH.map do |hash_key, settings|
          success = pbuddy.plist_set(settings[:key], settings[:type], settings[:value], plist_path)
          unless success
            if verbose
              if settings[:type] == 'bool'
                value = settings[:value] ? 'YES' : 'NO'
              else
                value = settings[:value]
              end
              msgs << "could not set #{hash_key} => '#{settings[:key]}' to #{value}"
              puts "WARN: #{msgs.join("\n")}"
            end
          end
          success
        end
        res.all?
      else
        FileUtils.mkdir_p("#{app_support_sdk_dir}/Library/Preferences")
        plist = CFPropertyList::List.new
        data = {}
        plist.value = CFPropertyList.guess(data)
        plist.save(plist_path, CFPropertyList::List::FORMAT_BINARY)
        enable_accessibility_in_sdk_dir(app_support_sdk_dir, merged_opts)
      end
    end

    # @!visibility private
    # Enables accessibility on the simulator indicated by `sim_data_dir`.
    #
    # @note This will quit the simulator.
    #
    # @note This is for Xcode 6 only.  Will raise an error if called on Xcode 5.
    #
    # @note The Accessibility plist contents differ by iOS version.  For
    #  example, iOS 8 uses Number instead of Boolean as the data type for
    #  several entries.  It is an _error_ to try to set a Number type to a
    #  Boolean value.  This is why we need the second arg:
    #  `sim_details_key_with_udid` which is a hash that maps a sim udid to a
    #  a simulator version number.  See the todo.
    #
    # @todo Should consider updating the API to pass just the version number instead
    #  of passing the entire sim_details hash.
    #
    # @example
    #   path = '~/Library/Developer/CoreSimulator/Devices/0BF52B67-F8BB-4246-A668-1880237DD17B'
    #   enable_accessibility_in_sim_data_dir(path, sim_details(:udid))
    #
    # This method also hides the AXInspector.
    #
    # If the Library/Preferences/com.apple.Accessibility.plist does not exist
    # this method will create a Library/Preferences/com.apple.Accessibility.plist
    # that (oddly) the Simulator will _not_ overwrite.
    #
    # @see #enable_accessibility_on_sims for the public API.
    #
    # @param [String] sim_data_dir The directory where the
    #   Library/Preferences/com.apple.Accessibility.plist can be found.
    # @param [Hash] sim_details_key_with_udid A hash table of simulator details
    #   that can be obtained by calling `sim_details(:udid)`.
    #
    # @param [Hash] opts controls the behavior of the method
    # @option opts [Boolean] :verbose controls logging output
    # @return [Boolean] if the plist exists and the plist was successfully
    #   updated.
    # @raise [RuntimeError] If called when Xcode 6 is _not_ the active Xcode version.
    def enable_accessibility_in_sim_data_dir(sim_data_dir, sim_details_key_with_udid, opts={})
      unless xcode_version_gte_6?
        raise RuntimeError, 'it is illegal to call this method when the Xcode < 6 is the current Xcode version'
      end

      default_opts = {:verbose => false}
      merged_opts = default_opts.merge(opts)

      quit_sim

      verbose = merged_opts[:verbose]
      target_udid = sim_data_dir[XCODE_6_SIM_UDID_REGEX, 0]
      launch_name = sim_details_key_with_udid[target_udid][:launch_name]
      sdk_version = sim_details_key_with_udid[target_udid][:sdk_version]

      msgs = ["cannot enable accessibility for '#{target_udid}' - '#{launch_name}'"]
      plist_path = File.expand_path("#{sim_data_dir}/Library/Preferences/com.apple.Accessibility.plist")

      if sdk_version >= RunLoop::Version.new('8.0')
        hash = SDK_80_ACCESSIBILITY_PROPERTIES_HASH
      else
        hash = SDK_LT_80_ACCESSIBILITY_PROPERTIES_HASH
      end

      unless File.exist? plist_path
        FileUtils.mkdir_p("#{sim_data_dir}/Library/Preferences")
        plist = CFPropertyList::List.new
        data = {}
        plist.value = CFPropertyList.guess(data)
        plist.save(plist_path, CFPropertyList::List::FORMAT_BINARY)
      end

      res = hash.map do |hash_key, settings|
        success = pbuddy.plist_set(settings[:key], settings[:type], settings[:value], plist_path)
        unless success
          if verbose
            if settings[:type] == 'bool'
              value = settings[:value] ? 'YES' : 'NO'
            else
              value = settings[:value]
            end
            msgs << "could not set #{hash_key} => '#{settings[:key]}' to #{value}"
            puts "WARN: #{msgs.join("\n")}"
          end
          end
        success
        end
      res.all?
    end

    # @!visibility private
    # Returns a hash table that contains detailed information about the
    # available simulators.  Use the `primary_key` to control the primary hash
    # key.  The same information is available regardless of the `primary_key`.
    # Choose a key that matches your access pattern.
    #
    # @note This is for Xcode 6 only.  Will raise an error if called on Xcode 5.
    #
    # @example :udid
    # "FD50223C-C29E-497A-BF16-0D6451318251" => {
    #       :launch_name => "iPad Retina (7.1 Simulator)",
    #       :udid => "FD50223C-C29E-497A-BF16-0D6451318251",
    #       :sdk_version => #<RunLoop::Version:0x007f8ee8a9aac8 @major=7, @minor=1, @patch=nil>
    # },
    # "21DED687-77F5-4125-A480-0DBA6A1BA6D1" => {
    #       :launch_name => "iPad Retina (8.0 Simulator)",
    #       :udid => "21DED687-77F5-4125-A480-0DBA6A1BA6D1",
    #       :sdk_version => #<RunLoop::Version:0x007f8ee8a9a730 @major=8, @minor=0, @patch=nil>
    # },
    #
    #
    # @example :launch_name
    # "iPad Retina (7.1 Simulator)" => {
    #       :launch_name => "iPad Retina (7.1 Simulator)",
    #       :udid => "FD50223C-C29E-497A-BF16-0D6451318251",
    #       :sdk_version => #<RunLoop::Version:0x007f8ee8a9aac8 @major=7, @minor=1, @patch=nil>
    # },
    # "iPad Retina (8.0 Simulator)" => {
    #       :launch_name => "iPad Retina (8.0 Simulator)",
    #       :udid => "21DED687-77F5-4125-A480-0DBA6A1BA6D1",
    #       :sdk_version => #<RunLoop::Version:0x007f8ee8a9a730 @major=8, @minor=0, @patch=nil>
    # },
    #
    # @param [Symbol] primary_key Can be on of `{:udid | :launch_name}`.
    # @raise [RuntimeError] If called when Xcode 6 is _not_ the active Xcode version.
    # @raise [RuntimeError] If called with an invalid `primary_key`.
    def sim_details(primary_key)
      unless xcode_version_gte_6?
        raise RuntimeError, 'this method is only available on Xcode >= 6'
      end

      allowed = [:udid, :launch_name]
      unless allowed.include? primary_key
        raise ArgumentError, "expected '#{primary_key}' to be one of '#{allowed}'"
      end

      hash = {}
      xctools.instruments(:sims).each do |elm|
        launch_name = elm[/\A.+\((\d\.\d(\.\d)? Simulator\))/, 0]
        udid = elm[XCODE_6_SIM_UDID_REGEX,0]
        sdk_version = elm[/(\d\.\d(\.\d)? Simulator)/, 0].split(' ').first
        value =
              {
                    :launch_name => launch_name,
                    :udid => udid,
                    :sdk_version => RunLoop::Version.new(sdk_version)
              }
        if primary_key == :udid
          key = udid
        else
          key = launch_name
        end
        hash[key] = value
      end
      hash
    end

    # @!visibility private
    # Uses the `simctl erase` command to reset the content and settings on _all_
    # simulators.
    #
    # @todo Should this reset _every_ simulator or just the targeted simulator?
    #  It is very slow to reset every simulator and if we are trying to respond
    #  to RESET_BETWEEN_SCENARIOS we probably want to erase just the current
    #  simulator.
    #
    # @note This is an Xcode 6 only method. Will raise an error if called on
    #  Xcode < 6.
    #
    # @note This method will quit the simulator.
    #
    # @raise [RuntimeError] If called on Xcode < 6.
    def simctl_reset
      unless xcode_version_gte_6?
        raise RuntimeError, 'this method is only available on Xcode >= 6'
      end

      quit_sim

      sim_details = sim_details(:udid)
      res = []
      sim_details.each_key do |key|
        cmd = "xcrun simctl erase #{key}"
        Open3.popen3(cmd) do  |_, stdout,  stderr, _|
          out = stdout.read.strip
          err = stderr.read.strip
          if ENV['DEBUG_UNIX_CALLS'] == '1'
            puts "#{cmd} => stdout: '#{out}' | stderr: '#{err}'"
          end
          res << err.empty?
        end
      end
      res.all?
    end

    # @!visibility private
    #
    # A ruby interface to the `simctl list` command.
    #
    # @note This is an Xcode >= 6.0 method.
    # @raise [RuntimeError] if called on Xcode < 6.0
    # @return [Hash] A hash whose primary key is a base SDK.  For example,
    #  SDK 7.0.3 => "7.0".  The value of the Hash will vary based on what is
    #  being listed.
    def simctl_list(what)
      unless xcode_version_gte_6?
        raise RuntimeError, 'simctl is only available on Xcode >= 6'
      end

      case what
        when :devices
          simctl_list_devices
        when :runtimes
          # The 'com.apple.CoreSimulator.SimRuntime.iOS-7-0' is the runtime-id,
          # which can be used to create devices.
          simctl_list_runtimes
        else
          allowed = [:devices, :runtimes]
          raise ArgumentError, "expected '#{what}' to be one of '#{allowed}'"
      end
    end

    # @!visibility private
    #
    # Helper method for simctl_list.
    #
    # @example
    #   RunLoop::SimControl.new.simctl_list :devices
    #   {
    #         "7.1" =>
    #               [
    #                     {
    #                           :name => "iPhone 4s",
    #                           :udid => "3BC5E3D7-9B81-4CE0-9C76-1888287F507B",
    #                           :state => "Shutdown"
    #                     }
    #               ],
    #         "8.0" => [
    #               {
    #                     :name => "iPad 2",
    #                     :udid => "D8F224D3-A59F-4F01-81AB-1959557A7E4E",
    #                     :state => "Shutdown"
    #               }
    #         ]
    #   }
    # @return [Hash<Array<Hash>>] Lists of available simulator details keyed by
    #  base sdk version.
    # @see #simctl_list
    def simctl_list_devices
      cmd = 'xcrun simctl list devices'
      Open3.popen3(cmd) do  |_, stdout,  stderr, _|
        out = stdout.read.strip
        err = stderr.read.strip
        if ENV['DEBUG_UNIX_CALLS'] == '1'
          puts "#{cmd} => stdout: '#{out}' | stderr: '#{err}'"
        end

        current_sdk = nil
        res = {}
        out.split("\n").each do |line|
          possible_sdk = line[/(\d\.\d(\.\d)?)/,0]
          if possible_sdk
            current_sdk = possible_sdk
            res[current_sdk] = []
            next
          end

          if current_sdk
            name = line.split('(').first.strip
            udid = line[XCODE_6_SIM_UDID_REGEX,0]
            state = line[/(Booted|Shutdown)/,0]
            res[current_sdk] << {:name => name, :udid => udid, :state => state}
          end
        end
        res
      end
    end

    # @!visibility private
    # Helper method for simctl_list
    #
    # @example
    #  RunLoop::SimControl.new.simctl_list :runtimes
    #  {
    #        "7.0" => {
    #              :sdk => "7.0.3",
    #              :runtime => "com.apple.CoreSimulator.SimRuntime.iOS-7-0"
    #        },
    #        "7.1" => {
    #              :sdk => "7.1",
    #              :runtime => "com.apple.CoreSimulator.SimRuntime.iOS-7-1"
    #        },
    #        "8.0" => {
    #              :sdk => "8.0",
    #              :runtime => "com.apple.CoreSimulator.SimRuntime.iOS-8-0"
    #        }
    #  }
    # @see #simctl_list
    def simctl_list_runtimes
      # The 'com.apple.CoreSimulator.SimRuntime.iOS-7-0' is the runtime-id,
      # which can be used to create devices.
      cmd = 'xcrun simctl list runtimes'
      Open3.popen3(cmd) do  |_, stdout,  stderr, _|
        out = stdout.read.strip
        err = stderr.read.strip
        if ENV['DEBUG_UNIX_CALLS'] == '1'
          puts "#{cmd}  => stdout: '#{out}' | stderr: '#{err}'"
        end
        # Ex.
        # == Runtimes ==
        # iOS 7.0 (7.0.3 - 11B507) (com.apple.CoreSimulator.SimRuntime.iOS-7-0)
        # iOS 7.1 (7.1 - 11D167) (com.apple.CoreSimulator.SimRuntime.iOS-7-1)
        # iOS 8.0 (8.0 - 12A4331d) (com.apple.CoreSimulator.SimRuntime.iOS-8-0)
        lines = out.split("\n").delete_if { |line| not line =~ /com.apple.CoreSimulator.SimRuntime/ }
        res = {}
        lines.each do |line|
          key = line[/iOS (\d.\d)/,1]
          sdk_version = line[/(\d.\d)(.\d)?\s-/, 0].tr(' -','')
          runtime = line[/com.apple.CoreSimulator.SimRuntime.iOS-\d-\d/,0]
          value = {:sdk => sdk_version,  :runtime => runtime}
          res[key] = value
        end
        res
      end
    end
  end
end
