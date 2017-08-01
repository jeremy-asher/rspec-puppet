require 'pathname'

class RSpec::Puppet::EventListener
  def self.example_started(example)
    @current_example = example
  end

  def self.current_example
    @current_example
  end
end

unless RSpec.respond_to?(:current_example)
  RSpec.configuration.reporter.register_listener(RSpec::Puppet::EventListener, :example_started)
end

module Puppet
  # Allow rspec-puppet to prevent Puppet::Type from automatically picking
  # a provider for a resource. We need to do this because in order to fully
  # resolve the graph edges, we have to convert the Puppet::Resource objects
  # into Puppet::Type objects so that their autorequires are evaluated. We need
  # to prevent provider code from being called during this process as it's very
  # platform specific.
  class Type
    old_set_default = instance_method(:set_default)

    define_method(:set_default) do |attr|
      if RSpec::Puppet.rspec_puppet_example?
        old_posix = nil
        old_microsoft_windows = nil

        if attr == :provider
          old_posix = Puppet.features.posix?
          old_microsoft_windows = Puppet.features.microsoft_windows?

          if Puppet::Util::Platform.pretend_windows?
            Puppet.features.add(:posix) { false }
            Puppet.features.add(:microsoft_windows) { true }
          else
            Puppet.features.add(:posix) { true }
            Puppet.features.add(:microsoft_windows) { false }
          end
        end

        retval = old_set_default.bind(self).call(attr)

        unless old_posix.nil?
          Puppet.features.add(:posix) { old_posix }
        end
        unless old_microsoft_windows.nil?
          Puppet.features.add(:microsoft_windows) { old_microsoft_windows }
        end

        retval
      else
        old_set_default.bind(self).call(attr)
      end
    end

    def self.suppress_provider?
      @suppress_provider ||= false
    end

    def self.suppress_provider
      @suppress_provider = true
    end

    def self.unsuppress_provider
      @suppress_provider = false
    end
  end

  # If Puppet::Node::Environment has a validate_dirs instance method (i.e.
  # Puppet < 3.x), wrap the method to check if rspec-puppet is pretending to be
  # running under windows. The original method uses Puppet::Util.absolute_path?
  # (which in turn calls Puppet::Util::Platform.windows?) to validate the path
  # to the manifests on disk during compilation, so we have to temporarily
  # disable the pretending when running it.
  class Node::Environment
    if instance_methods.include?("validate_dirs")
      old_validate_dirs = instance_method(:validate_dirs)

      define_method(:validate_dirs) do |dirs|
        if rspec_puppet_example?
          pretending = Puppet::Util::Platform.pretend_platform

          if pretending
            Puppet::Util::Platform.pretend_to_be nil
          end

          output = old_validate_dirs.bind(self).call(dirs)

          Puppet::Util::Platform.pretend_to_be pretending

          output
        else
          old_validate_dirs.bind(self).call(dirs)
        end
      end
    end
  end

  module Util
    # Allow rspec-puppet to pretend to be different platforms.
    module Platform
      alias :old_windows? :windows?
      module_function :old_windows?

      def windows?
        if RSpec::Puppet.rspec_puppet_example?
          pretend_platform.nil? ? (actual_platform == :windows) : pretend_windows?
        else
          old_windows?
        end
      end
      module_function :windows?

      def actual_platform
        @actual_platform ||= !!File::ALT_SEPARATOR ? :windows : :posix
      end
      module_function :actual_platform

      def pretend_windows?
        pretend_platform == :windows
      end
      module_function :pretend_windows?

      def pretend_to_be(platform)
        # Ensure that we cache the real platform before pretending to be
        # a different one
        actual_platform

        @pretend_platform = platform
      end
      module_function :pretend_to_be

      def pretend_platform
        @pretend_platform ||= nil
      end
      module_function :pretend_platform
    end
  end

  begin
    require 'puppet/confine/exists'

    class Confine::Exists < Puppet::Confine
      old_pass = instance_method(:pass?)

      define_method(:pass?) do |value|
        if RSpec::Puppet.rspec_puppet_example?
          true
        else
          old_pass.bind(self).call(value)
        end
      end
    end
  rescue LoadError
    require 'puppet/provider/confine/exists'

    class Provider::Confine::Exists < Puppet::Provider::Confine
      old_pass = instance_method(:pass?)

      define_method(:pass?) do |value|
        if RSpec::Puppet.rspec_puppet_example?
          true
        else
          old_pass.bind(self).call(value)
        end
      end
    end
  end
end

class Pathname
  def rspec_puppet_basename(path)
    raise ArgumentError, 'pathname stubbing not enabled' unless RSpec.configuration.enable_pathname_stubbing

    if path =~ /\A[a-zA-Z]:(#{SEPARATOR_PAT}.*)\z/
      path = path[2..-1]
    end
    path.split(SEPARATOR_PAT).last || path[/(#{SEPARATOR_PAT})/, 1] || path
  end

  if instance_methods.include?("chop_basename")
    old_chop_basename = instance_method(:chop_basename)

    define_method(:chop_basename) do |path|
      if RSpec::Puppet.rspec_puppet_example?
        if RSpec.configuration.enable_pathname_stubbing
          base = rspec_puppet_basename(path)
          if /\A#{SEPARATOR_PAT}?\z/o =~ base
            return nil
          else
            return path[0, path.rindex(base)], base
          end
        else
          old_chop_basename.bind(self).call(path)
        end
      else
        old_chop_basename.bind(self).call(path)
      end
    end
  end
end

# Prevent the File type from munging paths (which uses File.expand_path to
# normalise paths, which does very bad things to *nix paths on Windows.
file_path_munge = Puppet::Type.type(:file).paramclass(:path).instance_method(:unsafe_munge)
Puppet::Type.type(:file).paramclass(:path).munge do |value|
  if RSpec::Puppet.rspec_puppet_example?
    value
  else
    file_path_munge.bind(self).call(value)
  end
end

# Prevent the Exec type from validating the user. This parameter isn't
# supported under Windows at all and only under *nix when the current user is
# root.
exec_user_validate = Puppet::Type.type(:exec).paramclass(:user).instance_method(:unsafe_validate)
Puppet::Type.type(:exec).paramclass(:user).validate do |value|
  if RSpec::Puppet.rspec_puppet_example?
    true
  else
    exec_user_validate.bind(self).call(value)
  end
end

# Prevent Puppet from requiring 'puppet/util/windows' if we're pretending to be
# windows, otherwise it will require other libraries that probably won't be
# available on non-windows hosts.
module Kernel
  alias :old_require :require
  def require(path)
    return if path == 'puppet/util/windows' && RSpec::Puppet.rspec_puppet_example? && Puppet::Util::Platform.pretend_windows?
    old_require(path)
  end
end
