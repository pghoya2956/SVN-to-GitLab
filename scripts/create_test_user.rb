#!/usr/bin/env ruby
require File.expand_path('../../config/environment', __FILE__)

begin
  user = User.find_or_create_by(email: 'test@example.com') do |u|
    u.password = 'password'
    u.password_confirmation = 'password'
  end
  
  if user.persisted?
    puts "Test user created/found successfully: #{user.email}"
  else
    puts "Failed to create user: #{user.errors.full_messages.join(', ')}"
  end
rescue => e
  puts "Error: #{e.message}"
end