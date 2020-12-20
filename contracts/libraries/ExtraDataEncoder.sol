pragma solidity ^0.7.0;

library extraDataEncoder {
    function encode(
        uint256 _deadline, 
        uint256 _minPrice, 
        uint256 _rulingTimeout, 
        uint256 _appealTimeout, 
        address _backupArbitrator, 
        address[] memory _whiteList,
        bytes memory _backupArbitratorExtraData
    ) internal returns(bytes memory extraData) {
        uint256 whiteListLength = _backupArbitrator.length;
        extraData = abi.encodePacked(
            _deadline,
            _minPrice,
            _rulingTimeout,
            _appealTimeout,
            _backupArbitrator,
            whiteListLength,
            _whiteList,
            backupArbitratorExtraData
        );
    }
}