# Encoding: UTF-8

# rubocop:disable LineLength
#
# Cookbook Name:: wildfly
# Resource:: wildfly
#
# Copyright (C) 2018 Brian Dwyer - Intelligent Digital Services
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# => Shorten Hashes
wildfly = node['wildfly']

# => Define the Resource Name
resource_name :wildfly

# => Define the Resource Properties
property :service_name,   String, name_property: true
property :base_dir,       String, default: lazy { ::File.join(::File::SEPARATOR, 'opt', service_name) }
property :provision_user, [FalseClass, TrueClass], default: true
property :service_user,   String, default: lazy { service_name }
property :service_group,  String, default: lazy { service_name }
property :version,        String, default: wildfly['version']
property :url,            String, default: wildfly['url']
property :checksum,       String, default: wildfly['checksum']
property :mode,           String, equal_to: %w[domain standalone], default: wildfly['mode']
property :config,         String, default: 'standalone-full.xml'
property :log_dir,        String, default: lazy { ::File.join(base_dir, mode, 'log') }
# => Launch Arguments passed through to SystemD
property :launch_arguments,  Array, default: []
# => Properties to be dropped into service.properties file
property :server_properties, Array, default: []
# => Interface Binding
property :bind, String, default: '0.0.0.0'
property :bind_management_http, String, default: '9990'
# => JPDA Debugging Console
property :jpda_port, String, required: false

#
# => Define the Default Resource Action
#
default_action :install

#
# => Define the Install Action
#
action :install do # rubocop: disable BlockLength
  #
  # => Deploy the WildFly Application Server
  #

  # => Merge the Config
  wildfly = Chef::Mixin::DeepMerge.merge(node['wildfly'].to_h, node['wildfly'][new_resource.service_name])

  # => Break down SemVer
  _major, _minor, _patch = new_resource.version.split('.').map { |v| String(v) }

  if new_resource.provision_user
    # => Create WildFly System User
    user new_resource.service_user do
      comment 'WildFly System User'
      home new_resource.base_dir
      shell '/sbin/nologin'
      system true
      action [:create, :lock]
    end

    # => Create WildFly Group
    group new_resource.service_group do
      append true
      members new_resource.service_group
      action :create
      only_if { new_resource.service_user != new_resource.service_group }
    end
  end

  # => Create WildFly Directory
  directory "WildFly Base Directory (#{new_resource.service_name})" do
    path new_resource.base_dir
    owner new_resource.service_user
    group new_resource.service_group
    mode '0755'
    recursive true
  end

  # => Ensure LibAIO Present for Java NIO Journal
  case node['platform_family']
  when 'rhel'
    package 'libaio' do
      action :install
    end
  when 'debian'
    package 'libaio1' do
      action :install
    end
  end

  # => Download WildFly Tarball
  remote_file "Download WildFly #{new_resource.version}" do
    path ::File.join(Chef::Config[:file_cache_path], "#{new_resource.version}.tar.gz")
    source new_resource.url
    checksum new_resource.checksum
    action :create
    notifies :run, "bash[Extract WildFly #{new_resource.version}]", :immediately
    not_if { deployed? }
  end

  # => Extract WildFly
  bash "Extract WildFly #{new_resource.version}" do
    cwd Chef::Config[:file_cache_path]
    code <<-EOF
    tar xzf #{new_resource.version}.tar.gz -C #{new_resource.base_dir} --strip 1
    chown #{new_resource.service_user}:#{new_resource.service_group} -R #{new_resource.base_dir}
    rm -f #{::File.join(new_resource.base_dir, '.chef_deployed')}
    EOF
    action ::File.exist?(::File.join(new_resource.base_dir, '.chef_deployed')) ? :nothing : :run
  end

  # Deploy Service Configuration
  wf_cfgdir = directory 'WildFly Configuration Directory' do
    path '/etc/wildfly'
    action :create
  end

  wf_props = file 'WildFly Properties' do
    content new_resource.server_properties.join("\n")
    path ::File.join(wf_cfgdir.path, new_resource.service_name + '.properties')
    action :create
    notifies :restart, "service[#{new_resource.service_name}]", :delayed
  end

  systemd_service new_resource.service_name do
    unit_description 'The WildFly Application Server'
    unit_before %w[httpd.service]
    unit_after %w[syslog.target network.target remote-fs.target nss-lookup.target]
    install_wanted_by 'multi-user.target'
    service_pid_file "/var/run/wildfly/#{new_resource.service_name}.pid"
    service do
      environment(
        LAUNCH_JBOSS_IN_BACKGROUND: 1
      )
      service_user new_resource.service_user
      service_group new_resource.service_group
      exec_start [
        ::File.join(new_resource.base_dir, 'bin', new_resource.mode + '.sh'),
        "-c=#{new_resource.config}",
        "-b=#{new_resource.bind}",
        "-P=#{wf_props.path}",
        new_resource.launch_arguments.join(' ')
      ].join(' ')
      nice '-5'.to_i
      private_tmp true
      # standard_output 'null'
      verify false
    end
    notifies :restart, "service[#{new_resource.service_name}]", :delayed
  end

  # => Configure Logrotate for WildFly
  # template 'Wildfly Logrotate Configuration' do
  #   path ::File.join(::File::SEPARATOR, 'etc', 'logrotate.d', new_resource.service_name)
  #   source 'logrotate.erb'
  #   owner 'root'
  #   group 'root'
  #   mode '0644'
  #   only_if { ::File.directory?(::File.join(::File::SEPARATOR, 'etc', 'logrotate.d')) && wildfly['log']['rotation'] }
  #   action :create
  # end

  # log_dir = ::File.join(::File::SEPARATOR, 'var', 'log', service_name)
  # directory "Log Directory (#{new_resource.service_name})" do
  #   path new_resource.log_dir
  # end

  # logrotate_app service_name do
  #   cookbook 'logrotate'
  #   path [::File.join(log_dir, 'error.log')]
  #   frequency 'daily'
  #   options ['missingok', 'dateext', 'compress', 'notifempty', 'sharedscripts']
  #   postrotate "invoke-rc.d #{service_name} reopen-logs > /dev/null"
  #   rotate 30
  #   create '644 root root'
  # end

  # => Create file to indicate deployment and prevent recurring configuration deployment
  file ::File.join(new_resource.base_dir, '.chef_deployed') do
    content new_resource.version
    user new_resource.service_user
    group new_resource.service_group
    action :create_if_missing
  end

  # => Deploy Configuration
  ruby_block "Deploy WildFly Configuration (#{new_resource.service_name})" do
    block do
      new_resource.run_action(new_resource.mode.to_sym)
    end
  end

  # => Start the WildFly Service
  service new_resource.service_name do
    supports status: true, restart: true, reload: true
    action [:enable, :start]
  end
end

# => Define the Configure Standalone Mode Action
action :standalone do
  #
  # => Configure Standalone Mode
  #

  # => Configure Wildfly Standalone - MGMT Users
  template ::File.join(new_resource.base_dir, 'standalone', 'configuration', 'mgmt-users.properties') do
    source 'mgmt-users.properties.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0600'
    variables(
      mgmt_users: wildfly['users']['mgmt']
    )
  end

  # => Configure Wildfly Standalone - Application Users
  template ::File.join(new_resource.base_dir, 'standalone', 'configuration', 'application-users.properties') do
    source 'application-users.properties.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0600'
    variables(
      app_users: wildfly['users']['app']
    )
  end

  # => Configure Wildfly Standalone - Application Roles
  template ::File.join(new_resource.base_dir, 'standalone', 'configuration', 'application-roles.properties') do
    source 'application-roles.properties.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0600'
    variables(
      app_roles: wildfly['roles']['app']
    )
  end

  # => Configure Java Options - Standalone
  template ::File.join(new_resource.base_dir, 'bin', 'standalone.conf') do
    source 'standalone.conf.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0644'
    variables(
      xms: wildfly['java_opts']['xms'],
      xmx: wildfly['java_opts']['xmx'],
      maxpermsize: wildfly['java_opts']['xx_maxpermsize'],
      preferipv4: wildfly['java_opts']['preferipv4'],
      headless: wildfly['java_opts']['headless'],
      jpda: new_resource.jpda_port || false
    )
    notifies :restart, "service[#{service_name}]", :delayed
  end
end

action :domain do
  #
  # => Configure Domain Mode
  #

  # => Configure Wildfly Domain - MGMT Users
  template ::File.join(new_resource.base_dir, 'domain', 'configuration', 'mgmt-users.properties') do
    source 'mgmt-users.properties.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0600'
    variables(
      mgmt_users: wildfly['users']['mgmt']
    )
  end

  # => Configure Wildfly Domain - Application Users
  template ::File.join(new_resource.base_dir, 'domain', 'configuration', 'application-users.properties') do
    source 'application-users.properties.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0600'
    variables(
      app_users: wildfly['users']['app']
    )
  end

  # => Configure Wildfly Domain - Application Roles
  template ::File.join(new_resource.base_dir, 'domain', 'configuration', 'application-roles.properties') do
    source 'application-roles.properties.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0600'
    variables(
      app_roles: wildfly['roles']['app']
    )
  end

  # => Configure Java Options - Domain
  template ::File.join(new_resource.base_dir, 'bin', 'domain.conf') do
    source 'domain.conf.erb'
    user new_resource.service_user
    group new_resource.service_group
    mode '0644'
    variables(
      xms: wildfly['java_opts']['xms'],
      xmx: wildfly['java_opts']['xmx'],
      maxpermsize: wildfly['java_opts']['xx_maxpermsize'],
      preferipv4: wildfly['java_opts']['preferipv4'],
      headless: wildfly['java_opts']['headless'],
      jpda: new_resource.jpda_port || false
    )
    notifies :restart, "service[#{service_name}]", :delayed
    only_if { wildfly['mode'] == 'domain' }
  end
end

action_class.class_eval do
  def deployed?
    marker = ::File.join(new_resource.base_dir, '.chef_deployed')
    return false unless ::File.exist?(marker)
    ::File.read(marker) == new_resource.version
  end
end
