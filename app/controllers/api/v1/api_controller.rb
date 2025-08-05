module Api
  module V1
    class ApiController < ActionController::API
      before_action :authenticate_api_user!
      
      private
      
      def authenticate_api_user!
        token = request.headers['Authorization']&.split(' ')&.last
        
        unless token && valid_api_token?(token)
          render json: { 
            error: {
              code: 'authentication_error',
              message: 'Invalid or missing API token'
            }
          }, status: :unauthorized
        end
      end
      
      def valid_api_token?(token)
        # 실제 구현에서는 데이터베이스에서 토큰 검증
        # 임시로 환경 변수와 비교
        token == ENV['API_TOKEN']
      end
      
      def current_user
        @current_user ||= User.find_by_api_token(token) if token
      end
      
      def token
        request.headers['Authorization']&.split(' ')&.last
      end
    end
  end
end