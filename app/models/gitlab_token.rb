class GitlabToken < ApplicationRecord
  belongs_to :user
  
  validates :endpoint, presence: true, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }
  validates :encrypted_token, presence: true
  
  # Encrypt token before validation to ensure encrypted_token is set
  before_validation :encrypt_token
  
  attr_accessor :token
  
  def decrypt_token
    Base64.strict_decode64(encrypted_token) if encrypted_token.present?
  rescue
    nil
  end
  
  private
  
  def encrypt_token
    if token.present?
      self.encrypted_token = Base64.strict_encode64(token)
    end
  end
  
end
