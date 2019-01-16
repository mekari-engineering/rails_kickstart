require "fileutils"
require "shellwords"

# Copied from: https://github.com/mattbrictson/rails-template
# Add this template directory to source_paths so that Thor actions like
# copy_file and template resolve against our source files. If this file was
# invoked remotely via HTTP, that means the files are not present locally.
# In that case, use `git clone` to download them to a local temporary dir.
def add_template_repository_to_source_path
  if __FILE__ =~ %r{\Ahttps?://}
    require "tmpdir"
    source_paths.unshift(tempdir = Dir.mktmpdir("jumpstart-"))
    at_exit { FileUtils.remove_entry(tempdir) }
    git clone: [
      "--quiet",
      "https://github.com/sleekr/rails_kickstart.git",
      tempdir
    ].map(&:shellescape).join(" ")

    if (branch = __FILE__[%r{jumpstart/(.+)/template.rb}, 1])
      Dir.chdir(tempdir) { git checkout: branch }
    end
  else
    source_paths.unshift(File.dirname(__FILE__))
  end
end

def add_gems
  gem 'administrate', '~> 0.11.0'
  gem 'devise', '~> 4.5.0'
  gem 'fast_jsonapi', '~> 1.5'
  gem 'foreman', '~> 0.84.0'
  gem 'sidekiq', '~> 5.1', '>= 5.1.3'
  gem 'sidekiq-cron', '~> 0.6.3'

  gem_group :development, :test do
    gem 'rspec-rails'
    gem 'shoulda-matchers'
    gem 'factory_bot_rails'
    gem 'vcr'
    gem 'timecop'
    gem 'simplecov', require: false, group: :test
    gem 'simplecov-console', require: false, group: :test
    gem 'database_cleaner'
    gem 'webmock'
    gem 'dotenv-rails'
  end

  gem_group :development do
    gem 'bullet'
    gem 'guard-rspec', require: false
    gem 'rubycritic', '3.4.0', require: false
    gem 'spring-commands-rspec'
  end

  gem 'lograge'
end

def set_application_name
  # Add Application Name to Config
  environment "config.application_name = Rails.application.class.parent_name"

  # Announce the user where he can change the application name in the future.
  puts "You can change application name inside: ./config/application.rb"
end

def add_users
  # Install Devise
  generate "devise:install"

  # Configure Devise
  environment "config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }",
              env: 'development'
  route "root to: 'home#index'"


  # Create Devise User
  generate :devise, "AdminUser",
           "first_name",
           "last_name",
           "root:boolean"

  # Set admin default to false
  in_root do
    migration = Dir.glob("db/migrate/*").max_by{ |f| File.mtime(f) }
    gsub_file migration, /:root/, ":root, default: false"
  end

  requirement = Gem::Requirement.new("> 5.2")
  rails_version = Gem::Version.new(Rails::VERSION::STRING)

  if requirement.satisfied_by? rails_version
    gsub_file "config/initializers/devise.rb",
      /  # config.secret_key = .+/,
      "  config.secret_key = Rails.application.credentials.secret_key_base"
  end
end

def copy_templates
  directory "app", force: true
  directory "lib", force: true

  route "get '/terms', to: 'home#terms'"
  route "get '/privacy', to: 'home#privacy'"
end

def add_sidekiq
  environment "config.active_job.queue_adapter = :sidekiq"

  insert_into_file "config/routes.rb",
    "require 'sidekiq/web'\n\n",
    before: "Rails.application.routes.draw do"

  insert_into_file "config/routes.rb",
    "  authenticate :admin_user, lambda { |u| u.root? } do\n    mount Sidekiq::Web => '/sidekiq'\n  end\n\n",
    after: "Rails.application.routes.draw do\n"
end

def add_foreman
  copy_file "Procfile"
end

def add_administrate
  generate "administrate:install"

  gsub_file "app/dashboards/admin_user_dashboard.rb",
    /email: Field::String/,
    "email: Field::String,\n    password: Field::String.with_options(searchable: false)"

  gsub_file "app/dashboards/admin_user_dashboard.rb",
    /FORM_ATTRIBUTES = \[/,
    "FORM_ATTRIBUTES = [\n    :password,"

  gsub_file "app/controllers/admin/application_controller.rb",
    /# TODO Add authentication logic here\./,
    "redirect_to '/', alert: 'Not authorized.' unless admin_user_signed_in? && current_user.root?"
end

def add_app_helpers_to_administrate
  environment do <<-RUBY
    # Expose our application's helpers to Administrate
    config.to_prepare do
      Administrate::ApplicationController.helper #{@app_name.camelize}::Application.helpers
    end
  RUBY
  end
end

def install_rspec
  generate "rspec:install"
end

def install_shoulda_matcher
  gsub_file "spec/rails_helper.rb",
      /# config.filter_gems_from_backtrace.+/,
      "config.include(Shoulda::Matchers::ActiveModel, type: :model)
  config.include(Shoulda::Matchers::ActiveRecord, type: :model)"
end

# def add_multiple_authentication
#     insert_into_file "config/routes.rb",
#     ', controllers: { omniauth_callbacks: "users/omniauth_callbacks" }',
#     after: "  devise_for :users"

#     generate "model Service user:references provider uid access_token access_token_secret refresh_token expires_at:datetime auth:text"

#     template = """
#     env_creds = Rails.application.credentials[Rails.env.to_sym] || {}
#     %w{ facebook twitter github }.each do |provider|
#       if options = env_creds[provider]
#         confg.omniauth provider, options[:app_id], options[:app_secret], options.fetch(:options, {})
#       end
#     end
#     """.strip

#     insert_into_file "config/initializers/devise.rb", "  " + template + "\n\n",
#           before: "  # ==> Warden configuration"
# end

def stop_spring
  run "spring stop"
end

# Main setup
add_template_repository_to_source_path

add_gems

after_bundle do
  set_application_name
  stop_spring
  add_users
  add_sidekiq
  add_foreman
  install_rspec
  install_shoulda_matcher

  copy_templates

  # Migrate
  rails_command "db:create"
  rails_command "db:migrate"

  # Migrations must be done before this
  add_administrate

  add_app_helpers_to_administrate

  git :init
  git add: "."
  git commit: %Q{ -m 'Initial commit' }
end
