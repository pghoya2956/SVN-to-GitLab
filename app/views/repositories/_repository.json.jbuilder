json.extract! repository, :id, :name, :svn_url, :auth_type, :username, :encrypted_password, :ssh_key, :branch_option, :created_at, :updated_at
json.url repository_url(repository, format: :json)
