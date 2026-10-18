ActiveSupport.on_load(:action_view) do
  ActionView::Base.field_error_proc = Proc.new do |html_tag, _instance_tag|
    html_tag
  end
end
