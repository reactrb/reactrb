require 'spec_helper'

if ruby?
class TestController < ActionController::Base; end

RSpec.describe TestController, type: :controller do
  render_views

  describe '#render_component' do
    controller do
      def index
        render_component
      end
    end

    it 'renders the application layout' do
      get :index, prerender: true
      expect(response).to render_template(layout: :application)
    end
  end
end
end
