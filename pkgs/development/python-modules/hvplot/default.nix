{ lib
, bokeh
, buildPythonPackage
, colorcet
, fetchPypi
, holoviews
, pandas
, pythonOlder
}:

buildPythonPackage rec {
  pname = "hvplot";
  version = "0.9.1";
  format = "setuptools";

  disabled = pythonOlder "3.6";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-KB0YmiEtJkGT9446k079oWqTwBZMSFTakzW0LuBlazo=";
  };

  propagatedBuildInputs = [
    bokeh
    colorcet
    holoviews
    pandas
  ];

  # Many tests require a network connection
  doCheck = false;

  pythonImportsCheck = [
    "hvplot.pandas"
  ];

  meta = with lib; {
    description = "A high-level plotting API for the PyData ecosystem built on HoloViews";
    homepage = "https://hvplot.pyviz.org";
    changelog = "https://github.com/holoviz/hvplot/releases/tag/v${version}";
    license = licenses.bsd3;
    maintainers = with maintainers; [ ];
  };
}
