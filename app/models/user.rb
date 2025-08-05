class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  
  has_many :repositories, dependent: :destroy
  has_many :jobs, dependent: :destroy
  has_one :gitlab_token, dependent: :destroy
  
  # Thread-safe current user storage
  def self.current
    Thread.current[:current_user]
  end
  
  def self.current=(user)
    Thread.current[:current_user] = user
  end
end
