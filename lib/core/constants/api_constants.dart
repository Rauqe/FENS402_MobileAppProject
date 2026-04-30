/// API configuration for the FastAPI backend (AWS Lambda + API Gateway).
///
/// Update [kApiBaseUrl] with the actual deployed API Gateway URL.
/// The friend's backend runs on AWS Lambda behind API Gateway with
/// root_path="/default".
library api_constants;

const String kApiBaseUrl =
    'https://s766ccq1c7.execute-api.eu-north-1.amazonaws.com/default';

const Duration kApiTimeout = Duration(seconds: 15);
