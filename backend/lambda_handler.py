from mangum import Mangum
# from server import app
from server_openai import app

# Create the Lambda handler
handler = Mangum(app)