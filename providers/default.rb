def whyrun_supported?
  true
end

use_inline_resources

action :create do

  r = chef_gem 'chef-vault' do
    action :nothing
  end
  r.run_action(:install)
  Gem.clear_paths

  require 'openssl'
  require 'chef-vault'

  opt = { 'name' => new_resource.name.gsub(' ', '_') }
  %w[ data_bag ca path path_mode path_recursive owner group public_mode private_mode ].each do |attr|
    opt[attr] = new_resource.send(attr) ? new_resource.send(attr) : node['chef_vault_pki'][attr]
  end

  r = directory opt['path'] do
    owner opt['owner']
    group opt['group']
    mode opt['path_mode']
    recursive opt['path_recursive']
    action :nothing
  end
  r.run_action(:create)

  ca = ChefVault::Item.load(opt['data_bag'], opt['ca'])
  ca_key = OpenSSL::PKey::RSA.new ca['key']
  ca_cert = OpenSSL::X509::Certificate.new ca['cert']

  r = file ::File.join(opt['path'], "#{opt['name']}.crt") do
    owner opt['owner']
    group opt['group']
    mode opt['public_mode']
    content lazy { node.run_state['chef_vault_pki']['cert'] }
    action :nothing
  end

  r = file ::File.join(opt['path'], "#{opt['name']}.key") do
    owner opt['owner']
    group opt['group']
    mode opt['private_mode']
    content lazy { node.run_state['chef_vault_pki']['key'] }
    action :nothing
  end  

  r = ruby_block 'create_new_cert' do
    block do

      key = OpenSSL::PKey::RSA.new 2048

      csr = OpenSSL::X509::Request.new
      csr.version = 0
      csr.subject = OpenSSL::X509::Name.parse "CN=#{opt['name']}"
      csr.public_key = key.public_key
      csr.sign key, OpenSSL::Digest::SHA1.new

      csr_cert = OpenSSL::X509::Certificate.new
      csr_cert.serial = 0
      csr_cert.version = 2
      csr_cert.not_before = Time.now
      csr_cert.not_after = Time.now + 600

      csr_cert.subject = csr.subject
      csr_cert.public_key = csr.public_key
      csr_cert.issuer = ca_cert.subject

      extension_factory = OpenSSL::X509::ExtensionFactory.new
      extension_factory.subject_certificate = csr_cert
      extension_factory.issuer_certificate = ca_cert

      extension_factory.create_extension 'basicConstraints', 'CA:FALSE'
      extension_factory.create_extension 'keyUsage', 'keyEncipherment,dataEncipherment,digitalSignature'
      extension_factory.create_extension 'subjectKeyIdentifier', 'hash'

      csr_cert.sign ca_key, OpenSSL::Digest::SHA1.new

      node.run_state['chef_vault_pki'] = { 'cert' => csr_cert.to_pem, 'key' => key.to_pem }

      if not node.set['chef_vault_pki']['certs'].has_key? opt['ca']
        node.set['chef_vault_pki']['certs'][opt['ca']] = {}
      end

      node.set['chef_vault_pki']['certs'][opt['ca']][opt['name']] = csr_cert.to_pem
    end
    action :nothing
    notifies :create, resources(:file => ::File.join(opt['path'], "#{opt['name']}.crt")), :immediately
    notifies :create, resources(:file => ::File.join(opt['path'], "#{opt['name']}.key")), :immediately
  end

  r = file ::File.join(opt['path'], "#{opt['ca']}.crt") do
    owner opt['owner']
    group opt['group']
    mode opt['public_mode']
    content ca['cert']
    notifies :create, resources(:ruby_block => 'create_new_cert'), :immediately
  end

  new_resource.updated_by_last_action(true) if r.updated_by_last_action?
end

action :delete do

  opt = { 'name' => new_resource.name.gsub(' ', '_') }
  %w[ data_bag ca path path_mode path_recursive owner group public_mode private_mode ].each do |attr|
    opt[attr] = new_resource.send(attr) ? new_resource.send(attr) : node['chef_vault_pki'][attr]
  end

  #new_resource.updated_by_last_action(true) if resource.updated_by_last_action?
end
