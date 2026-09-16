class ParticipantAuthConfig
  include Auth::Config

  def allowed_origin?(origin)
    allow_origin?(origin, [ public_base_url ])
  end
end
